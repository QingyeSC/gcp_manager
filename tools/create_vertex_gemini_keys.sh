#!/bin/bash

# 并发创建GCP项目和Gemini API Key脚本

# 不使用set -e，避免并发任务中的错误导致主脚本退出
# set -e

PROJECT_COUNT=10
TIMESTAMP=$(date +%s)
LOG_FILE="gemini_keys_${TIMESTAMP}.log"
MAX_BILLING_CONCURRENCY=10
BILLING_RETRY=0
MAX_API_KEY_CONCURRENCY=${MAX_API_KEY_CONCURRENCY:-5}
BILLING_SUCCESS_FILE="billing_success_${TIMESTAMP}.tmp"
BILLING_FAILED_FILE="billing_failed_${TIMESTAMP}.tmp"
PROJECTS_FOR_KEYS_FILE="projects_for_keys_${TIMESTAMP}.tmp"
CREATED_PROJECTS_FILE="created_projects_${TIMESTAMP}.tmp"

if [ "$MAX_API_KEY_CONCURRENCY" -le 0 ]; then
    MAX_API_KEY_CONCURRENCY=1
fi

rm -f "$BILLING_SUCCESS_FILE" "$BILLING_FAILED_FILE" \
      "$PROJECTS_FOR_KEYS_FILE" "$CREATED_PROJECTS_FILE"
rm -f proj-*.json

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

# 并发为所有已创建的项目绑定账单
link_billing_for_created_projects() {
    log_info "扫描已创建的项目以绑定账单..."

    # 使用已创建的项目列表而不是重新查询
    if [ -f "$CREATED_PROJECTS_FILE" ]; then
        mapfile -t CREATED_PROJECTS < "$CREATED_PROJECTS_FILE"
        log_info "从创建记录中读取到 ${#CREATED_PROJECTS[@]} 个项目"
    else
        log_warning "未找到项目创建记录文件"
        return 1
    fi

    if [ ${#CREATED_PROJECTS[@]} -eq 0 ]; then
        log_warning "未找到任何已创建的项目"
        return 1
    fi

    log_info "共有 ${#CREATED_PROJECTS[@]} 个项目需要绑定，最大并发: $MAX_BILLING_CONCURRENCY"
    rm -f "$BILLING_SUCCESS_FILE" "$BILLING_FAILED_FILE"

    local -a running_pids=()
    for project_id in "${CREATED_PROJECTS[@]}"; do
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

# 为完成账单绑定的项目创建 Vertex AI API Key
process_project_for_key() {
    local project_id="$1"
    local sa_name="vertex-sa-${TIMESTAMP}"
    local sa_email="${sa_name}@${project_id}.iam.gserviceaccount.com"
    local api_key_name="vertex-key-${project_id}-${TIMESTAMP}"

    log_info "[$project_id] 启用 API Keys 服务..."
    if gcloud services enable apikeys.googleapis.com --project=$project_id --quiet >/dev/null 2>&1; then
        log_success "[$project_id] API Keys 服务启用成功"
    else
        log_error "[$project_id] API Keys 服务启用失败"
        return 1
    fi

    log_info "[$project_id] 启用 Vertex AI 服务..."
    if gcloud services enable aiplatform.googleapis.com --project=$project_id --quiet >/dev/null 2>&1; then
        log_success "[$project_id] Vertex AI 服务启用成功"
    else
        log_error "[$project_id] Vertex AI 服务启用失败"
        return 1
    fi

    log_info "[$project_id] 创建服务账号: $sa_email"
    local sa_attempt=0
    local sa_max_attempts=3
    local sa_created=false

    while [ $sa_attempt -lt $sa_max_attempts ]; do
        local sa_attempt_idx=$((sa_attempt + 1))
        log_info "[$project_id] 服务账号创建尝试第 $sa_attempt_idx 次..."
        if gcloud iam service-accounts create $sa_name \
            --display-name="Vertex AI Service Account" \
            --project=$project_id --quiet >/dev/null 2>&1; then
            log_success "[$project_id] 服务账号创建成功"
            sa_created=true
            break
        else
            # 检查服务账号是否已存在
            if gcloud iam service-accounts describe $sa_email --project=$project_id >/dev/null 2>&1; then
                log_info "[$project_id] 服务账号已存在，视为成功"
                sa_created=true
                break
            fi
            log_warning "[$project_id] 服务账号创建失败 (尝试 $sa_attempt_idx)"
        fi
        sa_attempt=$((sa_attempt + 1))
        if [ $sa_attempt -lt $sa_max_attempts ]; then
            sleep 2
        fi
    done

    if [ "$sa_created" = false ]; then
        log_error "[$project_id] 服务账号创建失败（超出重试次数）"
        return 1
    fi

    log_info "[$project_id] 授予服务账号 Vertex AI User 权限..."
    local iam_attempt=0
    local iam_max_attempts=3
    local iam_success=false

    while [ $iam_attempt -lt $iam_max_attempts ]; do
        local iam_attempt_idx=$((iam_attempt + 1))
        log_info "[$project_id] 权限授予尝试第 $iam_attempt_idx 次..."
        if gcloud projects add-iam-policy-binding $project_id \
            --member="serviceAccount:$sa_email" \
            --role="roles/aiplatform.user" \
            --quiet >/dev/null 2>&1; then
            log_success "[$project_id] 权限授予成功"
            iam_success=true
            break
        else
            log_warning "[$project_id] 权限授予失败 (尝试 $iam_attempt_idx)"
        fi
        iam_attempt=$((iam_attempt + 1))
        if [ $iam_attempt -lt $iam_max_attempts ]; then
            sleep 2
        fi
    done

    if [ "$iam_success" = false ]; then
        log_error "[$project_id] 权限授予失败（超出重试次数）"
        return 1
    fi

    log_info "[$project_id] 创建 API Key: $api_key_name"
    # 创建带限制的API Key：绑定服务账号、IP限制、API限制
    restrictions="--allowed-ips=152.53.169.193 --api-target=service=aiplatform.googleapis.com"

    if operation=$(gcloud alpha services api-keys create \
        --display-name="$api_key_name" \
        --project=$project_id \
        --service-account=$sa_email \
        $restrictions \
        --format="value(name)" 2>/dev/null); then
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
            # 获取项目详细信息
            project_name=$(gcloud projects describe $project_id --format="value(name)" 2>/dev/null)
            project_number=$(gcloud projects describe $project_id --format="value(projectNumber)" 2>/dev/null)

            # 生成JSON文件
            json_content=$(cat <<EOF
{
  "project_name": "$project_name",
  "project_id": "$project_id",
  "project_number": "$project_number",
  "api_key": "$api_key"
}
EOF
)
            echo "$json_content" > "${project_name}.json"
            log_success "[$project_id] JSON 文件已生成: ${project_name}.json"
            log_success "[$project_id] API Key 获取成功: ${api_key:0:10}..."
        else
            log_error "[$project_id] API Key 字符串获取失败"
            return 1
        fi
    else
        log_error "[$project_id] 未找到创建的 API Key"
        return 1
    fi
}

# 初始化日志
log_info "=== 开始创建 Vertex AI API Keys ==="
log_info "项目数量: $PROJECT_COUNT"
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

log_info "账单解绑检查完成，开始创建新项目..."

# 获取邮箱前缀（遇到特殊字符跳过）
get_email_prefix() {
    local email="$1"
    local prefix=$(echo "$email" | cut -d'@' -f1)
    local domain=$(echo "$email" | cut -d'@' -f2)

    # 清理前缀：只保留字母和数字，特殊字符直接跳过
    prefix=$(echo "$prefix" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')

    # 如果是gmail.com，取前7个字符（不够就用全部）
    if [ "$domain" = "gmail.com" ]; then
        if [ ${#prefix} -ge 7 ]; then
            echo "${prefix:0:7}"
        else
            echo "$prefix"
        fi
    else
        # 其他邮箱用全部前缀
        echo "$prefix"
    fi
}

# 获取并处理邮箱前缀
ACTIVE_EMAIL=$(gcloud config get-value account 2>/dev/null || echo "unknown@gmail.com")
EMAIL_PREFIX=$(get_email_prefix "$ACTIVE_EMAIL")
log_info "邮箱: $ACTIVE_EMAIL, 前缀: $EMAIL_PREFIX"

# 创建项目函数
create_project() {
    local i=$1
    local project_name="proj-${EMAIL_PREFIX}-svip-${i}"

    log_info "【项目$i】开始创建项目 (名称: $project_name)"

    # 创建项目，让 GCP 自动生成 project_id
    log_info "【项目$i】创建 GCP 项目..."
    if project_id=$(gcloud projects create --name="$project_name" --format="value(projectId)" --quiet 2>/dev/null); then
        log_success "【项目$i】项目创建成功: $project_id (名称: $project_name)"
        printf '%s\n' "$project_id" >> "$CREATED_PROJECTS_FILE"
        log_success "【项目$i】项目创建完成: $project_id，后续将尝试绑定账单"
    else
        log_error "【项目$i】项目创建失败: $project_name"
        return 1
    fi
}

# 并发创建所有项目
log_info "开始并发创建 $PROJECT_COUNT 个项目..."
for i in $(seq 1 $PROJECT_COUNT); do
    create_project $i &
done

# 等待所有后台任务完成
log_info "等待所有项目创建任务完成..."
wait

# 批量为所有已创建的项目绑定账单
link_billing_for_created_projects

# 所有绑定成功的项目都生成 API Key
READY_FOR_KEYS=()
if [ -f "$BILLING_SUCCESS_FILE" ]; then
    mapfile -t READY_FOR_KEYS < "$BILLING_SUCCESS_FILE"
    log_info "共有 ${#READY_FOR_KEYS[@]} 个项目成功绑定账单，将为它们创建 Vertex AI API Key"
else
    log_warning "未找到成功绑定账单的项目"
fi

if [ ${#READY_FOR_KEYS[@]} -gt 0 ]; then
    log_info "准备为 ${#READY_FOR_KEYS[@]} 个项目创建 Vertex AI API Key，最大并发: $MAX_API_KEY_CONCURRENCY"
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
    log_warning "没有成功绑定账单的目标项目可用于创建 Vertex AI API Key"
fi

# 统计生成的JSON文件
log_info "统计生成的 JSON 文件..."
JSON_COUNT=$(ls -1 proj-*.json 2>/dev/null | wc -l)
if [ $JSON_COUNT -gt 0 ]; then
    log_success "成功生成 $JSON_COUNT 个项目 JSON 文件"
    log_info "生成的 JSON 文件列表："
    ls -1 proj-*.json | while IFS= read -r json_file; do
        log_success "  - $json_file"
    done
else
    log_warning "未找到任何 JSON 文件"
fi

log_info "项目创建总结："
TOTAL_CREATED_COUNT=$(grep -c '.' "$CREATED_PROJECTS_FILE" 2>/dev/null || echo 0)
READY_FOR_KEYS_COUNT=${#READY_FOR_KEYS[@]}
BILLING_SUCCESS_COUNT=$(grep -c '.' "$BILLING_SUCCESS_FILE" 2>/dev/null || echo 0)
log_info "  - 目标创建数量: $PROJECT_COUNT"
log_info "  - 实际创建成功: $TOTAL_CREATED_COUNT 个"
log_info "  - 账单绑定成功项目: $BILLING_SUCCESS_COUNT 个"
log_info "  - 进入 API Key 处理的项目: $READY_FOR_KEYS_COUNT 个"
log_info "  - 成功生成 JSON 文件: $JSON_COUNT 个"

# 上传到 Auto Channel Manager
AUTO_UPLOAD="${AUTO_UPLOAD:-true}"
MANAGER_API_URL="${MANAGER_API_URL:-http://152.53.82.146:5358/api/accounts/upload}"

if [ "$AUTO_UPLOAD" = "true" ] && [ $JSON_COUNT -gt 0 ]; then
    log_info "准备上传 JSON 文件到 Auto Channel Manager: $MANAGER_API_URL"

    # 构建 curl 命令，批量上传所有 JSON 文件
    curl_cmd="curl -s -X POST"

    # 添加所有 JSON 文件
    for json_file in proj-*.json; do
        if [ -f "$json_file" ]; then
            curl_cmd="$curl_cmd -F 'files=@$json_file'"
        fi
    done

    curl_cmd="$curl_cmd '$MANAGER_API_URL'"

    # 执行上传
    log_info "执行上传命令..."
    response=$(eval "$curl_cmd" 2>&1)
    exit_code=$?

    if [ $exit_code -eq 0 ]; then
        if echo "$response" | grep -q '"success".*true'; then
            log_success "✅ 成功上传 JSON 文件到 Auto Channel Manager"
            log_info "服务器响应: $response"

            # 提取上传成功的文件数
            saved_count=$(echo "$response" | grep -o '"saved":\[[^]]*\]' | grep -o ',' | wc -l)
            saved_count=$((saved_count + 1))
            log_success "已上传 $saved_count 个 JSON 文件到管理系统"
        else
            log_warning "⚠️  上传响应异常: $response"
            log_info "JSON 文件已保存在本地，可稍后手动上传"
        fi
    else
        log_warning "⚠️  上传失败，可能管理服务未启动"
        log_info "错误信息: $response"
        log_info "JSON 文件已保存在本地: $(ls -1 proj-*.json | tr '\n' ' ')"
        log_info "可使用以下命令手动上传:"
        log_info "  python auto-channel-manager/tools/upload_to_manager.py ."
    fi
else
    if [ "$AUTO_UPLOAD" != "true" ]; then
        log_info "自动上传已禁用（设置 AUTO_UPLOAD=true 以启用）"
    fi
    if [ $JSON_COUNT -gt 0 ]; then
        log_info "JSON 文件已保存在本地，可使用以下命令手动上传:"
        log_info "  python auto-channel-manager/tools/upload_to_manager.py ."
    fi
fi

log_info "=== 脚本执行完成 ==="
log_info "日志文件: $LOG_FILE"
if [ $JSON_COUNT -gt 0 ]; then
    log_success "JSON 文件已保存在当前目录，文件名格式: proj-*.json"
fi

# 清理临时文件
rm -f "$PROJECTS_FOR_KEYS_FILE" "$CREATED_PROJECTS_FILE" \
      "$BILLING_SUCCESS_FILE" "$BILLING_FAILED_FILE"
