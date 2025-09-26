#!/bin/bash

# 并发创建GCP项目和Gemini API Key脚本
# 先解绑账单默认项目，然后创建3个项目，并发执行，显示详细日志

set -e

PROJECT_COUNT=3
TIMESTAMP=$(date +%s)
LOG_FILE="gemini_keys_${TIMESTAMP}.log"

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
log_info "=== 开始创建 Gemini API Keys ==="
log_info "项目数量: $PROJECT_COUNT"
log_info "时间戳: $TIMESTAMP"
log_info "日志文件: $LOG_FILE"

# 检查是否已登录
log_info "检查 GCloud 认证状态..."
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -n1 > /dev/null; then
    log_error "未检测到活跃的 GCloud 认证，请先运行 gcloud auth login"
    exit 1
fi

ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -n1)
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

# 创建单个项目的函数
create_project() {
    local i=$1
    local project_id="gemini-project-${TIMESTAMP}-${i}"
    local api_key_name="gemini-key-$i"

    log_info "【项目$i】开始创建项目: $project_id"

    # 创建项目
    log_info "【项目$i】创建 GCP 项目..."
    if gcloud projects create $project_id --name="Gemini Project $i" --quiet >/dev/null 2>&1; then
        log_success "【项目$i】项目创建成功: $project_id"
    else
        log_error "【项目$i】项目创建失败: $project_id"
        return 1
    fi

    # 设置当前项目
    log_info "【项目$i】设置当前项目..."
    if gcloud config set project $project_id --quiet >/dev/null 2>&1; then
        log_success "【项目$i】项目设置成功"
    else
        log_error "【项目$i】项目设置失败"
        return 1
    fi

    # 绑定账单账户
    log_info "【项目$i】绑定账单账户..."
    if gcloud beta billing projects link $project_id --billing-account=$BILLING_ACCOUNT --quiet >/dev/null 2>&1; then
        log_success "【项目$i】账单账户绑定成功"
    else
        log_error "【项目$i】账单账户绑定失败"
        return 1
    fi

    # 启用API服务
    log_info "【项目$i】启用 API Keys 服务..."
    if gcloud services enable apikeys.googleapis.com --quiet >/dev/null 2>&1; then
        log_success "【项目$i】API Keys 服务启用成功"
    else
        log_error "【项目$i】API Keys 服务启用失败"
        return 1
    fi

    log_info "【项目$i】启用 Generative Language 服务..."
    if gcloud services enable generativelanguage.googleapis.com --quiet >/dev/null 2>&1; then
        log_success "【项目$i】Generative Language 服务启用成功"
    else
        log_error "【项目$i】Generative Language 服务启用失败"
        return 1
    fi

    # 创建API Key
    log_info "【项目$i】创建 API Key: $api_key_name"
    if operation=$(gcloud services api-keys create --display-name="$api_key_name" --format="value(name)" 2>/dev/null); then
        log_success "【项目$i】API Key 创建操作已提交: $operation"
    else
        log_error "【项目$i】API Key 创建失败"
        return 1
    fi

    # 等待操作完成
    log_info "【项目$i】等待 API Key 操作完成..."
    if gcloud services operations wait "$operation" --quiet >/dev/null 2>&1; then
        log_success "【项目$i】API Key 操作完成"
    else
        log_error "【项目$i】API Key 操作等待失败"
        return 1
    fi

    # 获取API Key
    log_info "【项目$i】获取 API Key 详情..."
    key_name=$(gcloud services api-keys list --filter="displayName:$api_key_name" --format="value(name)" --limit=1 2>/dev/null)
    if [ -n "$key_name" ]; then
        log_success "【项目$i】找到 API Key: $key_name"
        api_key=$(gcloud services api-keys get-key-string "$key_name" --format="value(keyString)" 2>/dev/null)
        if [ -n "$api_key" ]; then
            echo "$api_key" > "key_${i}.tmp"
            log_success "【项目$i】API Key 获取成功并保存: ${api_key:0:10}..."
        else
            log_error "【项目$i】API Key 字符串获取失败"
            return 1
        fi
    else
        log_error "【项目$i】未找到创建的 API Key"
        return 1
    fi
}

# 并发创建项目
log_info "开始并发创建 $PROJECT_COUNT 个项目..."
for i in $(seq 1 $PROJECT_COUNT); do
    create_project $i &
done

# 等待所有后台任务完成
log_info "等待所有项目创建任务完成..."
wait

# 合并所有临时key文件到key.txt
log_info "合并所有 API Keys 到 key.txt..."
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
else
    log_warning "未找到任何 API Key 文件"
fi

# 清理临时文件
rm -f key_*.tmp

log_info "=== 脚本执行完成 ==="
log_info "日志文件: $LOG_FILE"
log_info "API Keys 文件: key.txt"
