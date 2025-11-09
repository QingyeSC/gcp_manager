#!/bin/bash

# 并发创建GCP项目并为每个项目创建 Gemini API Key（generativelanguage.googleapis.com）
# 说明：此脚本使用 GCP 的 API Keys 服务创建并限制到 generativelanguage.googleapis.com 的 API Key，
# 可用于以“Gemini API（Google AI for Developers）”方式调用端点（https://generativelanguage.googleapis.com）。
# 这与 Vertex AI 的密钥不同，前者是“Google AI for Developers”API Key，后者是 Vertex 项目级调用方式。

# 不使用 set -e，避免并发任务中的错误导致主脚本退出
# set -e

PROJECT_COUNT=${PROJECT_COUNT:-5}
TIMESTAMP=$(date +%s)
LOG_FILE="gemini_api_keys_${TIMESTAMP}.log"
MAX_BILLING_CONCURRENCY=${MAX_BILLING_CONCURRENCY:-10}
BILLING_RETRY=${BILLING_RETRY:-0}
MAX_API_KEY_CONCURRENCY=${MAX_API_KEY_CONCURRENCY:-5}
BILLING_SUCCESS_FILE="billing_success_${TIMESTAMP}.tmp"
BILLING_FAILED_FILE="billing_failed_${TIMESTAMP}.tmp"
CREATED_PROJECTS_FILE="created_projects_${TIMESTAMP}.tmp"

API_SERVICE="generativelanguage.googleapis.com"

if [ "$MAX_API_KEY_CONCURRENCY" -le 0 ]; then
    MAX_API_KEY_CONCURRENCY=1
fi

rm -f "$BILLING_SUCCESS_FILE" "$BILLING_FAILED_FILE" "$CREATED_PROJECTS_FILE"
rm -f proj-*.json

# 日志函数
log() {
    local level="$1"; shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log_info() { log INFO "$@"; }
log_error() { log ERROR "$@"; }
log_success() { log SUCCESS "$@"; }
log_warning() { log WARNING "$@"; }

# 单个项目绑定账单（含重试）
link_project_billing_worker() {
    local project_id="$1"
    local attempt=0
    local max_attempts=$((BILLING_RETRY + 1))

    while [ $attempt -lt $max_attempts ]; do
        local idx=$((attempt + 1))
        log_info "【账单】项目 $project_id 绑定尝试第 $idx 次..."
        if gcloud beta billing projects link "$project_id" --billing-account="$BILLING_ACCOUNT" --quiet >/dev/null 2>&1; then
            log_success "【账单】项目 $project_id 账单绑定成功"
            printf '%s\n' "$project_id" >> "$BILLING_SUCCESS_FILE"
            return 0
        else
            log_warning "【账单】项目 $project_id 绑定失败 (尝试 $idx)"
            current_account=$(gcloud beta billing projects describe "$project_id" --format="value(billingAccountName)" 2>/dev/null)
            if [ "$current_account" = "$BILLING_ACCOUNT" ]; then
                log_info "【账单】项目 $project_id 已绑定到账户，视为成功"
                printf '%s\n' "$project_id" >> "$BILLING_SUCCESS_FILE"
                return 0
            fi
        fi
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then sleep 1; fi
    done

    log_error "【账单】项目 $project_id 绑定失败（超出重试次数）"
    printf '%s\n' "$project_id" >> "$BILLING_FAILED_FILE"
    return 1
}

# 并发为所有已创建的项目绑定账单
link_billing_for_created_projects() {
    log_info "扫描已创建的项目以绑定账单..."

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
        [ -z "$project_id" ] && continue
        while [ ${#running_pids[@]} -ge $MAX_BILLING_CONCURRENCY ]; do
            local new_pids=()
            for pid in "${running_pids[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then new_pids+=("$pid"); fi
            done
            running_pids=("${new_pids[@]}")
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

    local success_count=0 failure_count=0
    [ -f "$BILLING_SUCCESS_FILE" ] && success_count=$(grep -c '.' "$BILLING_SUCCESS_FILE" 2>/dev/null || echo 0)
    [ -f "$BILLING_FAILED_FILE" ] && failure_count=$(grep -c '.' "$BILLING_FAILED_FILE" 2>/dev/null || echo 0)
    log_info "账单绑定完成：成功 $success_count 个，失败 $failure_count 个"
    [ $failure_count -gt 0 ] && log_warning "绑定失败的项目详见: $BILLING_FAILED_FILE"
}

# 为账单绑定成功的项目创建 Gemini API Key
process_project_for_key() {
    local project_id="$1"
    local api_key_name="gemini-key-${project_id}-${TIMESTAMP}"

    log_info "[$project_id] 启用 API Keys 服务..."
    if gcloud services enable apikeys.googleapis.com --project="$project_id" --quiet >/dev/null 2>&1; then
        log_success "[$project_id] API Keys 服务启用成功"
    else
        log_error "[$project_id] API Keys 服务启用失败"; return 1
    fi

    log_info "[$project_id] 启用 Generative Language API ($API_SERVICE)..."
    if gcloud services enable "$API_SERVICE" --project="$project_id" --quiet >/dev/null 2>&1; then
        log_success "[$project_id] Generative Language API 启用成功"
    else
        log_error "[$project_id] Generative Language API 启用失败"; return 1
    fi

    log_info "[$project_id] 创建并限制 API Key: $api_key_name"
    local restrictions="--api-target=service=$API_SERVICE"
    local operation
    if operation=$(gcloud alpha services api-keys create \
        --display-name="$api_key_name" \
        --project="$project_id" \
        $restrictions \
        --format="value(name)" 2>/dev/null); then
        log_success "[$project_id] API Key 创建操作已提交: $operation"
    else
        log_error "[$project_id] API Key 创建失败"; return 1
    fi

    log_info "[$project_id] 等待 API Key 操作完成..."
    if gcloud services operations wait "$operation" --project="$project_id" --quiet >/dev/null 2>&1; then
        log_success "[$project_id] API Key 操作完成"
    else
        log_error "[$project_id] API Key 操作等待失败"; return 1
    fi

    log_info "[$project_id] 获取 API Key 详情..."
    local key_name
    key_name=$(gcloud services api-keys list --filter="displayName:$api_key_name" --project="$project_id" --format="value(name)" --limit=1 2>/dev/null)
    if [ -z "$key_name" ]; then
        log_error "[$project_id] 未找到创建的 API Key"; return 1
    fi
    log_success "[$project_id] 找到 API Key: $key_name"

    local api_key
    api_key=$(gcloud services api-keys get-key-string "$key_name" --project="$project_id" --format="value(keyString)" 2>/dev/null)
    if [ -z "$api_key" ]; then
        log_error "[$project_id] API Key 字符串获取失败"; return 1
    fi

    # 记录到聚合 Key 列表（不再逐个生成 JSON 文件）
    printf '%s\n' "$api_key" >> "$BUNDLE_KEYS_FILE"
    log_success "[$project_id] 已加入聚合 Key 列表"
}

log_info "=== 开始创建 Gemini API Keys（$API_SERVICE） ==="
log_info "目标项目数量: $PROJECT_COUNT"
log_info "时间戳: $TIMESTAMP"
log_info "日志文件: $LOG_FILE"

# 检查是否已登录
log_info "检查 GCloud 认证状态..."
ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -n1)
if [ -z "$ACTIVE_ACCOUNT" ]; then
    log_error "未检测到活跃的 GCloud 认证，请先运行: gcloud auth login"
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

# 获取邮箱前缀（用于项目命名）
get_email_prefix() {
    local email="$1"
    local prefix=$(echo "$email" | cut -d'@' -f1)
    local domain=$(echo "$email" | cut -d'@' -f2)
    prefix=$(echo "$prefix" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
    if [ "$domain" = "gmail.com" ]; then
        if [ ${#prefix} -ge 7 ]; then echo "${prefix:0:7}"; else echo "$prefix"; fi
    else
        echo "$prefix"
    fi
}

ACTIVE_EMAIL=$(gcloud config get-value account 2>/dev/null || echo "unknown@gmail.com")
EMAIL_PREFIX=$(get_email_prefix "$ACTIVE_EMAIL")
log_info "邮箱: $ACTIVE_EMAIL, 前缀: $EMAIL_PREFIX"

# 聚合 Key 的临时与输出文件（同一号聚合）
BUNDLE_KEYS_FILE="bundle_keys_${EMAIL_PREFIX}_${TIMESTAMP}.tmp"
BUNDLE_JSON_FILE="proj-${EMAIL_PREFIX}-gem-bundle-${TIMESTAMP}.json"

# 创建项目函数（不做任何危险的解绑操作）
create_project() {
    local i=$1
    local project_name="proj-${EMAIL_PREFIX}-gem-${i}"
    log_info "【项目$i】开始创建项目 (名称: $project_name)"

    log_info "【项目$i】创建 GCP 项目..."
    local project_id
    if project_id=$(gcloud projects create --name="$project_name" --format="value(projectId)" --quiet 2>/dev/null); then
        log_success "【项目$i】项目创建成功: $project_id (名称: $project_name)"
        printf '%s\n' "$project_id" >> "$CREATED_PROJECTS_FILE"
    else
        log_error "【项目$i】项目创建失败: $project_name"; return 1
    fi
}

log_info "开始并发创建 $PROJECT_COUNT 个项目..."
for i in $(seq 1 $PROJECT_COUNT); do
    create_project $i &
done

log_info "等待所有项目创建任务完成..."
wait

# 批量为所有已创建的项目绑定账单
link_billing_for_created_projects

# 为账单绑定成功的项目生成 Gemini API Key
READY_FOR_KEYS=()
if [ -f "$BILLING_SUCCESS_FILE" ]; then
    mapfile -t READY_FOR_KEYS < "$BILLING_SUCCESS_FILE"
    log_info "共有 ${#READY_FOR_KEYS[@]} 个项目成功绑定账单，将为它们创建 Gemini API Key"
else
    log_warning "未找到成功绑定账单的项目"
fi

if [ ${#READY_FOR_KEYS[@]} -gt 0 ]; then
    log_info "准备为 ${#READY_FOR_KEYS[@]} 个项目创建 Gemini API Key，最大并发: $MAX_API_KEY_CONCURRENCY"
    API_JOB_PIDS=()
    for project_id in "${READY_FOR_KEYS[@]}"; do
        while [ ${#API_JOB_PIDS[@]} -ge $MAX_API_KEY_CONCURRENCY ]; do
            local new_pids=()
            for pid in "${API_JOB_PIDS[@]}"; do
                if kill -0 "$pid" 2>/dev/null; then new_pids+=("$pid"); fi
            done
            API_JOB_PIDS=("${new_pids[@]}")
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
        if ! wait "$pid" 2>/dev/null; then API_OVERALL_STATUS=1; fi
    done
    [ $API_OVERALL_STATUS -ne 0 ] && log_warning "部分项目的 API Key 创建失败，详见前述日志"
else
    log_warning "没有成功绑定账单的目标项目可用于创建 Gemini API Key"
fi

## 生成同一号的聚合 JSON（仅包含 api_keys 列表）
log_info "构建聚合 JSON（同一号合并）..."
JSON_COUNT=0
if [ -f "$BUNDLE_KEYS_FILE" ]; then
    KEYS_COUNT=$(grep -c '.' "$BUNDLE_KEYS_FILE" 2>/dev/null || echo 0)
    if [ "$KEYS_COUNT" -gt 0 ]; then
        # 组装为 JSON 数组字符串
        keys_json=$(awk 'BEGIN{printf("[")} {gsub(/"/,"\\\""); if(NR>1)printf(","); printf("\"%s\"", $0)} END{printf("]")}' "$BUNDLE_KEYS_FILE")
        cat > "$BUNDLE_JSON_FILE" <<EOF
{
  "project_name": "${EMAIL_PREFIX}-gem-bundle-${TIMESTAMP}",
  "group_prefix": "${EMAIL_PREFIX}",
  "api_keys": ${keys_json},
  "service": "${API_SERVICE}",
  "note": "bundle file generated by create_gemini_api_keys.sh"
}
EOF
        JSON_COUNT=1
        log_success "聚合 JSON 已生成: $BUNDLE_JSON_FILE (keys: $KEYS_COUNT)"
    else
        log_warning "聚合 Key 列表为空，跳过生成聚合 JSON"
    fi
else
    log_warning "未找到聚合 Key 列表文件，跳过生成聚合 JSON"
fi

# 可选：上传到 Auto Channel Manager（与现有脚本保持一致）
AUTO_UPLOAD="${AUTO_UPLOAD:-true}"
# 默认上传到本项目的管理接口（可通过 MANAGER_API_URL 覆盖）
MANAGER_API_URL="${MANAGER_API_URL:-http://152.53.82.146:5358/api/accounts/upload}"

if [ "$AUTO_UPLOAD" = "true" ] && [ $JSON_COUNT -gt 0 ]; then
    log_info "准备上传聚合 JSON 到新 API: $MANAGER_API_URL"
    tmp_body="/tmp/upload_body_$$.log"
    http_out=$(curl -s -X POST -F "files=@$BUNDLE_JSON_FILE" "$MANAGER_API_URL" -w $'\n%{http_code}' -o "$tmp_body" 2>&1)
    curl_code=$?
    http_code=$(tail -n1 <<< "$http_out" | tr -d '\r\n')
    body=$(cat "$tmp_body" 2>/dev/null || true)
    rm -f "$tmp_body"

    if [ $curl_code -eq 0 ] && [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        log_success "✅ 成功上传聚合 JSON (HTTP $http_code)"
        [ -n "$body" ] && log_info "服务器响应: $body"
    else
        log_warning "⚠️  上传失败 (curl=$curl_code, HTTP=$http_code)"
        [ -n "$body" ] && log_info "响应: $body"
        log_info "聚合 JSON 已保存在本地: $BUNDLE_JSON_FILE"
        log_info "可使用以下命令手动上传:"
        log_info "  python auto-channel-manager/tools/upload_to_manager.py ."
    fi
else
    [ "$AUTO_UPLOAD" != "true" ] && log_info "自动上传已禁用（设置 AUTO_UPLOAD=true 以启用）"
    [ $JSON_COUNT -gt 0 ] && log_info "JSON 文件已保存在本地，可使用以下命令手动上传:\n  python auto-channel-manager/tools/upload_to_manager.py ."
fi

log_info "=== 脚本执行完成 ==="
log_info "日志文件: $LOG_FILE"
[ $JSON_COUNT -gt 0 ] && log_success "聚合 JSON 已保存在当前目录: $BUNDLE_JSON_FILE"

# 清理临时文件
rm -f "$CREATED_PROJECTS_FILE" "$BILLING_SUCCESS_FILE" "$BILLING_FAILED_FILE" "$BUNDLE_KEYS_FILE"
