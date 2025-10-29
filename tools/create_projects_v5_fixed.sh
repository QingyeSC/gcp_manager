#!/bin/bash

# GCP项目批量创建脚本 v5.1
# 优化版：实时进度显示、并发处理、自动上传、添加重试机制

# 默认配置
PROJECT_COUNT=25
TIMESTAMP=$(date +%Y%m%d%H%M%S)
LOG_FILE="create_projects_v5_${TIMESTAMP}.log"

# 并发控制参数
MAX_PROJECT_CONCURRENCY=${MAX_PROJECT_CONCURRENCY:-25}
MAX_PERMISSION_CONCURRENCY=${MAX_PERMISSION_CONCURRENCY:-10}
MAX_API_CONCURRENCY=${MAX_API_CONCURRENCY:-5}

# 服务器配置（请修改为你的实际服务器地址）
SERVER_HOST=${SERVER_HOST:-"152.53.82.146"}
SERVER_PORT=${SERVER_PORT:-"8065"}
UPLOAD_ENDPOINT="http://${SERVER_HOST}:${SERVER_PORT}/api/upload-batch"

# 服务账号相关文件
SERVICE_ACCOUNT_JSON_FILE="service-account-${TIMESTAMP}.json"

# 临时文件
PROJECTS_INFO_FILE="projects_info_${TIMESTAMP}.tmp"
PROGRESS_FILE="progress_${TIMESTAMP}.tmp"

# 初始化变量
TOTAL_CREATED=0
EMAIL_PREFIX=""
CREATED_COUNT=0
FAILED_COUNT=0

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 清理旧文件
rm -f "$PROJECTS_INFO_FILE" "$PROGRESS_FILE" key_*.tmp key.txt *.json

# 日志函数
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log_info() { echo -e "${BLUE}[INFO]${NC} $*" | tee -a "$LOG_FILE"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $*" | tee -a "$LOG_FILE"; }
log_warning() { echo -e "${YELLOW}[WARNING]${NC} $*" | tee -a "$LOG_FILE"; }

# 显示进度条
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((current * width / total))

    printf "\r["
    printf "%${completed}s" | tr ' ' '='
    printf "%$((width - completed))s" | tr ' ' '>'
    printf "] %3d%% (%d/%d)" $percentage $current $total

    if [ $current -eq $total ]; then
        echo ""
    fi
}

# 实时显示创建进度
monitor_progress() {
    local total=$1
    while true; do
        if [ -f "$PROGRESS_FILE" ]; then
            local created=$(grep "created" "$PROGRESS_FILE" 2>/dev/null | wc -l)
            local failed=$(grep "failed" "$PROGRESS_FILE" 2>/dev/null | wc -l)
            local current=$((created + failed))

            show_progress $current $total

            if [ $current -ge $total ]; then
                break
            fi
        fi
        sleep 0.5
    done
    echo ""
}

# 检查必要的权限
check_permissions() {
    log_info "检查必要的权限..."

    # 检查是否能列出项目
    if ! gcloud projects list --limit=1 >/dev/null 2>&1; then
        log_error "无法列出项目，请检查您的权限"
        return 1
    fi

    # 检查是否能访问账单
    if ! gcloud beta billing accounts list --limit=1 >/dev/null 2>&1; then
        log_error "无法访问账单账户，请确认："
        log_error "1. 您已激活300美元赠金"
        log_error "2. 您有billing相关权限"
        return 1
    fi

    log_success "权限检查通过"
    return 0
}

# 邮箱前缀处理函数
process_email_prefix() {
    local email="$1"
    local prefix=$(echo "$email" | cut -d'@' -f1)

    # 转小写
    prefix=$(echo "$prefix" | tr '[:upper:]' '[:lower:]')

    # 替换特殊字符为连字符
    local clean_prefix=""
    for (( i=0; i<${#prefix}; i++ )); do
        char="${prefix:$i:1}"
        if [[ "$char" =~ [a-z0-9] ]]; then
            clean_prefix+="$char"
        else
            # 如果不是最后一个字符且下一个字符不是连字符，添加连字符
            if [ $i -lt $((${#prefix} - 1)) ] && [ "${clean_prefix: -1}" != "-" ]; then
                clean_prefix+="-"
            fi
        fi
    done

    # 移除开头和结尾的连字符
    clean_prefix=$(echo "$clean_prefix" | sed 's/^-//;s/-$//')

    # 截取前10个字符
    clean_prefix="${clean_prefix:0:10}"

    echo "$clean_prefix"
}

# 创建项目并发函数（带重试）
create_project_job() {
    local index=$1
    local prefix=$2
    local suffix=$3
    local max_retries=3
    local retry=0

    # 格式化索引
    local formatted_index=$(printf "%02d" "$index")

    local project_name="proj-${prefix}-svip-${formatted_index}"
    local project_id="${project_name}-${suffix}"
    local display_name="${prefix} SVIP ${formatted_index}"

    # 创建项目（带重试）
    while [ $retry -lt $max_retries ]; do
        if gcloud projects create "$project_id" \
            --name="$display_name" \
            --quiet >/dev/null 2>&1; then

            echo "$project_name|$project_id|$display_name|created" >> "$PROJECTS_INFO_FILE"
            echo "created" >> "$PROGRESS_FILE"
            return 0
        fi

        ((retry++))
        [ $retry -lt $max_retries ] && sleep 2
    done

    # 所有重试失败
    echo "failed" >> "$PROGRESS_FILE"
    return 1
}

# 批量创建项目
create_projects() {
    log_info "开始批量创建 $PROJECT_COUNT 个项目..."

    # 获取当前账号信息
    local email=$(gcloud config get-value account 2>/dev/null)
    log_info "当前账号: $email"

    # 处理邮箱前缀
    EMAIL_PREFIX=$(process_email_prefix "$email")
    log_info "使用项目前缀: $EMAIL_PREFIX"

    # 生成随机后缀（用于项目ID的唯一性）
    local suffix=$(cat /dev/urandom | tr -dc '0-9' | fold -w 6 | head -n 1)

    echo -e "${BLUE}创建进度：${NC}"

    # 启动进度监控
    monitor_progress $PROJECT_COUNT &
    local monitor_pid=$!

    local job_pids=()

    for i in $(seq 1 $PROJECT_COUNT); do
        # 控制并发数量
        while [ ${#job_pids[@]} -ge $MAX_PROJECT_CONCURRENCY ]; do
            # 检查已完成的任务
            local new_pids=()
            for pid in "${job_pids[@]}"; do
                if kill -0 $pid 2>/dev/null; then
                    new_pids+=($pid)
                fi
            done
            job_pids=("${new_pids[@]}")
            sleep 0.1
        done

        # 启动新任务
        create_project_job $i "$EMAIL_PREFIX" "$suffix" &
        job_pids+=($!)
    done

    # 等待所有任务完成
    for pid in "${job_pids[@]}"; do
        wait $pid
    done

    # 停止进度监控
    kill $monitor_pid 2>/dev/null
    wait $monitor_pid 2>/dev/null

    # 统计结果
    if [ -f "$PROJECTS_INFO_FILE" ]; then
        TOTAL_CREATED=$(wc -l < "$PROJECTS_INFO_FILE")
    fi

    log_success "项目创建完成！成功: $TOTAL_CREATED / $PROJECT_COUNT"
}

# 并发授权函数（带重试）
grant_permission_job() {
    local project_id=$1
    local sa_email=$2
    local max_retries=3
    local retry=0

    while [ $retry -lt $max_retries ]; do
        if gcloud projects add-iam-policy-binding "$project_id" \
            --member="serviceAccount:$sa_email" \
            --role="roles/owner" \
            --quiet >/dev/null 2>&1; then
            echo -n "."
            return 0
        fi

        ((retry++))
        [ $retry -lt $max_retries ] && sleep 2
    done

    echo -n "!"
    return 1
}

# 并发启用API函数（带重试）
enable_api_job() {
    local api_name=$1
    local project_id=$2
    local max_retries=3
    local retry=0

    while [ $retry -lt $max_retries ]; do
        if gcloud services enable "$api_name" \
            --project="$project_id" \
            --quiet >/dev/null 2>&1; then
            echo -n "."
            return 0
        fi

        ((retry++))
        [ $retry -lt $max_retries ] && sleep 3
    done

    echo -n "!"
    return 1
}

# 解绑默认项目的账单
unbind_default_project_billing() {
    log_info "检查并解绑默认项目的账单绑定..."

    # 获取账单账户
    local billing_account=$(get_billing_account)
    if [ -z "$billing_account" ]; then
        log_warning "未找到账单账户，跳过解绑"
        return 0
    fi

    # 确保账单账户格式正确
    if [[ ! "$billing_account" =~ ^billingAccounts/ ]]; then
        billing_account="billingAccounts/$billing_account"
    fi

    # 获取当前绑定账单的项目
    local billed_projects=$(gcloud beta billing projects list \
        --billing-account="$billing_account" \
        --format="value(projectId)" 2>/dev/null)

    if [ -z "$billed_projects" ]; then
        log_info "没有项目绑定到账单账户"
        return 0
    fi

    # 解绑所有默认项目（通常是 My First Project 等）
    local unbound_count=0
    for project_id in $billed_projects; do
        # 检查是否是我们创建的项目（包含 svip）
        if [[ ! "$project_id" =~ svip ]]; then
            log_info "解绑默认项目 $project_id 的账单..."
            if gcloud beta billing projects unlink "$project_id" --quiet >/dev/null 2>&1; then
                log_success "成功解绑项目 $project_id"
                ((unbound_count++))
            else
                log_warning "无法解绑项目 $project_id（可能没有权限）"
            fi
        fi
    done

    if [ $unbound_count -gt 0 ]; then
        log_success "共解绑 $unbound_count 个默认项目"
    else
        log_info "没有需要解绑的默认项目"
    fi
}

# 创建服务账号
create_service_account() {
    log_info "开始创建服务账号..."

    # 首先解绑默认项目的账单（如果有）
    unbind_default_project_billing

    # 获取第一个项目作为服务账号的宿主项目
    local host_project
    host_project=$(head -n1 "$PROJECTS_INFO_FILE" | cut -d'|' -f2)

    if [ -z "$host_project" ]; then
        log_error "没有可用的项目来创建服务账号"
        return 1
    fi

    # 创建服务账号名称
    local sa_name="gemini-sa-$(date +%m%d%H%M)"
    local sa_email="${sa_name}@${host_project}.iam.gserviceaccount.com"

    log_info "在项目 $host_project 中创建服务账号 $sa_name"

    # 创建服务账号
    if ! gcloud iam service-accounts create "$sa_name" \
        --display-name="Gemini Service Account" \
        --project="$host_project" \
        --quiet >/dev/null 2>&1; then
        log_error "服务账号创建失败"
        return 1
    fi

    log_success "服务账号创建成功: $sa_email"

    # 授予账单管理权限
    log_info "为服务账号授予账单管理权限..."

    # 获取账单账户
    local billing_account=$(get_billing_account)
    if [ -n "$billing_account" ]; then
        # 确保账单账户格式正确（添加前缀如果需要）
        if [[ ! "$billing_account" =~ ^billingAccounts/ ]]; then
            billing_account="billingAccounts/$billing_account"
        fi

        # 为服务账号授予账单用户权限
        if gcloud beta billing accounts add-iam-policy-binding "$billing_account" \
            --member="serviceAccount:$sa_email" \
            --role="roles/billing.admin" \
            --quiet >/dev/null 2>&1; then
            log_success "成功授予账单管理员权限"
        else
            # 如果admin权限失败，尝试user权限
            if gcloud beta billing accounts add-iam-policy-binding "$billing_account" \
                --member="serviceAccount:$sa_email" \
                --role="roles/billing.user" \
                --quiet >/dev/null 2>&1; then
                log_success "成功授予账单用户权限"
            else
                log_warning "无法授予账单权限，可能需要手动设置"
            fi
        fi
    else
        log_warning "未找到账单账户，跳过账单权限设置"
    fi

    # 并发授予所有项目的Owner权限
    log_info "为服务账号授予所有项目的Owner权限（并发处理）..."
    echo -n "  进度: "

    local job_pids=()
    while IFS='|' read -r project_name project_id display_name status; do
        if [ "$status" = "created" ]; then
            # 控制并发数量
            while [ ${#job_pids[@]} -ge $MAX_PERMISSION_CONCURRENCY ]; do
                local new_pids=()
                for pid in "${job_pids[@]}"; do
                    if kill -0 $pid 2>/dev/null; then
                        new_pids+=($pid)
                    fi
                done
                job_pids=("${new_pids[@]}")
                sleep 0.1
            done

            grant_permission_job "$project_id" "$sa_email" &
            job_pids+=($!)
        fi
    done < "$PROJECTS_INFO_FILE"

    # 等待所有授权完成
    for pid in "${job_pids[@]}"; do
        wait $pid
    done
    echo " 完成！"

    # 并发启用必要的API
    log_info "为服务账号启用必要的API（并发处理）..."

    local apis=(
        "cloudresourcemanager.googleapis.com"
        "serviceusage.googleapis.com"
        "cloudbilling.googleapis.com"
        "iam.googleapis.com"
        "apikeys.googleapis.com"
        "servicemanagement.googleapis.com"
    )

    echo -n "  进度: "
    job_pids=()
    for api in "${apis[@]}"; do
        # 控制并发数量
        while [ ${#job_pids[@]} -ge $MAX_API_CONCURRENCY ]; do
            local new_pids=()
            for pid in "${job_pids[@]}"; do
                if kill -0 $pid 2>/dev/null; then
                    new_pids+=($pid)
                fi
            done
            job_pids=("${new_pids[@]}")
            sleep 0.1
        done

        enable_api_job "$api" "$host_project" &
        job_pids+=($!)
    done

    # 等待所有API启用完成
    for pid in "${job_pids[@]}"; do
        wait $pid
    done
    echo " 完成！"

    # 等待API启用生效
    log_info "等待API服务生效..."
    sleep 5

    # 创建服务账号密钥
    log_info "创建服务账号密钥文件..."
    if gcloud iam service-accounts keys create "$SERVICE_ACCOUNT_JSON_FILE" \
        --iam-account="$sa_email" \
        --project="$host_project" \
        --quiet >/dev/null 2>&1; then
        log_success "服务账号密钥创建成功: $SERVICE_ACCOUNT_JSON_FILE"
        return 0
    else
        log_error "服务账号密钥创建失败"
        return 1
    fi
}

# 获取账单账户信息
get_billing_info() {
    # 获取第一个开放的账单账户的ID和名称
    local billing_info
    billing_info=$(gcloud beta billing accounts list \
        --filter="open=true" \
        --format="csv[no-heading](name,displayName)" \
        --limit=1 2>/dev/null)

    if [ -z "$billing_info" ]; then
        # 返回空字符串
        echo "|"
        return 1
    fi

    # 返回格式: billing_id|billing_name
    echo "$billing_info" | awk -F',' '{
        # 移除billingAccounts/前缀
        gsub("billingAccounts/", "", $1);
        print $1 "|" $2
    }'
}

# 兼容旧函数名
get_billing_account() {
    local billing_info=$(get_billing_info)
    echo "$billing_info" | cut -d'|' -f1
}

# 生成上传JSON
generate_upload_json() {
    local output_file="upload_data_${TIMESTAMP}.json"

    log_info "生成上传数据文件..." >&2

    # 获取当前账号信息
    local email=$(gcloud config get-value account 2>/dev/null)

    # 获取账单账户信息
    log_info "获取账单账户信息..." >&2
    local billing_info=$(get_billing_info)
    local billing_id=$(echo "$billing_info" | cut -d'|' -f1)
    local billing_name=$(echo "$billing_info" | cut -d'|' -f2)

    if [ -z "$billing_id" ]; then
        log_warning "未找到可用的账单账户，需要手动设置" >&2
        billing_id="NEED_TO_SET_MANUALLY"
        billing_name="NEED_TO_SET_MANUALLY"
    else
        log_success "找到账单账户: $billing_id ($billing_name)" >&2
    fi

    # 读取服务账号JSON内容
    local service_account_json=""
    if [ -f "$SERVICE_ACCOUNT_JSON_FILE" ]; then
        service_account_json=$(cat "$SERVICE_ACCOUNT_JSON_FILE" | jq -c .)
    fi

    cat > "$output_file" << EOF
{
  "account": {
    "email": "$email",
    "account_type": 0,
    "service_account_json": $service_account_json,
    "billing_id": "$billing_id",
    "billing_name": "$billing_name",
    "billing_status": 1
  },
  "projects": [
EOF

    local first=true

    # 处理所有项目
    while IFS='|' read -r project_name project_id display_name status; do
        if [ "$status" = "created" ]; then
            if [ "$first" = false ]; then
                echo "," >> "$output_file"
            else
                first=false
            fi

            cat >> "$output_file" << EOF
    {
      "project_name": "$project_name",
      "project_id": "$project_id",
      "api_key": null,
      "billing_linked": 0,
      "is_used": 0,
      "status": 1
    }
EOF
        fi
    done < "$PROJECTS_INFO_FILE"

    cat >> "$output_file" << EOF

  ],
  "summary": {
    "total_projects": $TOTAL_CREATED,
    "account_type": "待自动检测",
    "billing_id": "$billing_id",
    "billing_name": "$billing_name",
    "note": "账单绑定和API激活将由系统自动完成"
  }
}
EOF

    log_success "上传数据文件已生成: $output_file" >&2
    echo "$output_file"
}

# 自动上传到服务器
auto_upload() {
    local json_file=$1

    echo ""
    log_info "========== 自动上传到服务器 =========="
    log_info "目标服务器: ${SERVER_HOST}:${SERVER_PORT}"
    log_info "上传端点: $UPLOAD_ENDPOINT"
    log_info "数据文件: $json_file"

    # 检查文件是否存在
    if [ ! -f "$json_file" ]; then
        log_error "上传文件不存在: $json_file"
        return 1
    fi

    # 检查服务器是否可达
    echo -n "检查服务器连接..."
    if curl -s --connect-timeout 5 "http://${SERVER_HOST}:${SERVER_PORT}/api" >/dev/null 2>&1; then
        echo -e " ${GREEN}✓ 服务器可达${NC}"
    else
        echo -e " ${RED}✗ 服务器不可达${NC}"
        log_warning "服务器 ${SERVER_HOST}:${SERVER_PORT} 不可达"
        log_warning "请手动上传文件: $json_file"
        log_warning "或者设置正确的服务器地址: export SERVER_HOST=your-server-ip"
        return 1
    fi

    # 上传数据
    log_info "正在上传数据..."
    response=$(curl -s -w "\nHTTP_CODE:%{http_code}" -X POST "$UPLOAD_ENDPOINT" \
        -H "Content-Type: application/json" \
        -d @"$json_file" 2>&1)

    http_code=$(echo "$response" | grep "HTTP_CODE:" | cut -d':' -f2)
    response_body=$(echo "$response" | grep -v "HTTP_CODE:")

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        if echo "$response_body" | grep -q '"success"\s*:\s*true\|"status"\s*:\s*"success"'; then
            log_success "✅ 数据上传成功！"
            log_info "服务器响应: $response_body"
            return 0
        else
            log_warning "上传完成但响应不确定"
            log_info "HTTP状态码: $http_code"
            log_info "响应内容: $response_body"
            return 0
        fi
    else
        log_error "❌ 上传失败"
        log_error "HTTP状态码: $http_code"
        log_error "错误信息: $response_body"
        log_warning "请手动上传文件: $json_file"
        return 1
    fi
}

# 显示最终摘要
show_summary() {
    echo ""
    echo -e "${GREEN}=================================="
    echo "        创建完成摘要"
    echo "==================================${NC}"
    echo -e "${BLUE}账号邮箱:${NC} $(gcloud config get-value account 2>/dev/null)"
    echo -e "${BLUE}项目前缀:${NC} $EMAIL_PREFIX"
    echo -e "${BLUE}创建成功:${NC} $TOTAL_CREATED / $PROJECT_COUNT 个项目"
    echo ""
    echo -e "${YELLOW}生成的文件:${NC}"
    echo "  - 服务账号密钥: $SERVICE_ACCOUNT_JSON_FILE"
    echo "  - 上传数据文件: upload_data_${TIMESTAMP}.json"
    echo "  - 详细日志: $LOG_FILE"
    echo ""
    echo -e "${GREEN}系统将自动完成：${NC}"
    echo "  ✅ 检测账号配额（3或5）"
    echo "  ✅ 绑定账单到前N个项目"
    echo "  ✅ 生成API密钥"
    echo "  ✅ 上传到New API"
    echo -e "${GREEN}==================================${NC}"
}

# 主流程
main() {
    clear
    echo -e "${GREEN}=== GCP项目批量创建脚本 v5.0 ===${NC}"
    echo -e "${BLUE}开始时间: $(date)${NC}"
    echo ""

    # 检查权限
    if ! check_permissions; then
        log_error "权限检查失败，退出脚本"
        exit 1
    fi

    # 创建项目
    create_projects

    if [ $TOTAL_CREATED -eq 0 ]; then
        log_error "没有成功创建任何项目，退出脚本"
        exit 1
    fi

    # 创建服务账号
    create_service_account

    # 生成上传JSON
    json_file=$(generate_upload_json)

    # 尝试自动上传
    auto_upload "$json_file"

    # 显示摘要
    show_summary

    echo ""
    log_success "脚本执行完成: $(date)"
}

# 捕获中断信号
trap "echo -e '\n${RED}脚本被中断${NC}'; exit 1" INT TERM

# 执行主流程
main "$@"
