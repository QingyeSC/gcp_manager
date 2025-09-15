#!/bin/bash

#####################################################
#                   配置变量                         #
#####################################################

# 要创建的项目数量（可以通过命令行参数修改）
PROJECT_COUNT=${1:-50}

# 项目名前缀
PROJECT_PREFIX_LETTER="proj"

# 项目命名中的连接词
PROJECT_SUFFIX="vip"

# 服务账号前缀
SERVICE_ACCOUNT_PREFIX_LETTER="sa"

# 每个项目创建的服务账号数量
SERVICE_ACCOUNTS_PER_PROJECT=1

# 并发控制
MAX_PARALLEL_JOBS=50

# 重试配置
MAX_RETRIES=2
BASE_RETRY_DELAY=3

# JSON上传配置
UPLOAD_API_URL="${UPLOAD_API_URL:-http://152.53.82.146:5001/api/upload-files}"
UPLOAD_API_TOKEN="${UPLOAD_API_TOKEN:-}"

# 需要开启的API列表
APIS_TO_ENABLE=(
  "aiplatform.googleapis.com"
)

# 需要授予服务账号的角色
SERVICE_ACCOUNT_ROLES=(
  "roles/aiplatform.user"
  "roles/iam.serviceAccountTokenCreator"
)

# 临时文件用于跟踪进度
PROGRESS_DIR="/tmp/gcp_script_$$"
mkdir -p "$PROGRESS_DIR"

# 成功绑定账单的项目列表
SUCCESSFULLY_BILLED_PROJECTS=()

# 清理函数
function cleanup {
    rm -rf "$PROGRESS_DIR"
}
trap cleanup EXIT

#####################################################
#                   辅助函数                         #
#####################################################

# 函数：显示错误信息并退出
function error_exit {
    echo "❌ 错误: $1" >&2
    exit 1
}

# 函数：显示分隔线
function show_separator {
    echo "=================================================="
}

# 函数：显示进度
function show_progress {
    local current=$1
    local total=$2
    local task=$3
    echo "📊 进度: [$current/$total] $task"
}

# 函数：重试执行命令
function retry_command {
    local max_retries=$1
    local base_delay=$2
    shift 2
    local cmd="$*"
    
    for ((i=1; i<=max_retries; i++)); do
        if eval "$cmd"; then
            return 0
        else
            if [ $i -lt $max_retries ]; then
                local delay=$((base_delay * i))
                echo "⚠️  命令执行失败，第 $i 次重试，等待 ${delay}s..."
                sleep $delay
            fi
        fi
    done
    
    echo "❌ 命令执行失败（已重试 $max_retries 次）: $cmd"
    return 1
}

# 函数：并发控制执行
function run_parallel {
    local max_jobs=$1
    shift
    local jobs=("$@")
    
    for ((i=0; i<${#jobs[@]}; i+=max_jobs)); do
        for ((j=i; j<i+max_jobs && j<${#jobs[@]}; j++)); do
            eval "${jobs[j]}" &
        done
        wait
    done
}

# 函数：解绑单个项目账单
function unlink_project {
    local project_id=$1
    local billing_account=$2
    
    if retry_command $MAX_RETRIES $BASE_RETRY_DELAY \
        "gcloud billing projects unlink '$project_id' --quiet 2>/dev/null"; then
        echo "✓ 项目 $project_id 账单解绑成功"
        echo "$project_id" >> "$PROGRESS_DIR/unlinked_projects"
    else
        echo "⚠️  项目 $project_id 账单解绑失败（可能未绑定账单）"
    fi
}

# 函数：创建单个项目
function create_project {
    local project_name=$1
    
    echo "🏗️  正在创建项目: $project_name"
    
    # 使用GCP自动生成项目ID，获取生成的项目ID
    local project_id
    project_id=$(gcloud projects create --name="$project_name" --format="value(projectId)" --quiet 2>/dev/null)
    local create_result=$?
    
    if [ $create_result -eq 0 ] && [ ! -z "$project_id" ]; then
        echo "✓ 项目 '$project_name' 创建成功，自动生成ID: $project_id"
        echo "$project_id:$project_name" >> "$PROGRESS_DIR/created_projects"
    else
        echo "❌ 项目 '$project_name' 创建失败"
        echo "$project_name" >> "$PROGRESS_DIR/failed_projects"
    fi
}

# 函数：为项目绑定账单
function link_billing {
    local project_id=$1
    local billing_account=$2
    local billing_name=$3
    
    if retry_command $MAX_RETRIES $BASE_RETRY_DELAY \
        "gcloud billing projects link '$project_id' --billing-account='$billing_account' --quiet"; then
        echo "✓ 项目 $project_id 成功绑定账单 $billing_name"
        echo "$project_id:$billing_account" >> "$PROGRESS_DIR/linked_billing"
    else
        echo "❌ 项目 $project_id 绑定账单失败"
        echo "$project_id:$billing_account" >> "$PROGRESS_DIR/failed_billing"
    fi
}

# 函数：为项目启用API
function enable_apis {
    local project_id=$1
    
    echo "🔧 正在为项目 $project_id 启用API服务..."
    
    # 设置当前项目
    gcloud config set project "$project_id" --quiet
    
    local success_count=0
    for api in "${APIS_TO_ENABLE[@]}"; do
        if retry_command $MAX_RETRIES $((BASE_RETRY_DELAY * 2)) \
            "gcloud services enable '$api' --project='$project_id' --quiet"; then
            echo "  ✓ $api 启用成功"
            ((success_count++))
        else
            echo "  ❌ $api 启用失败"
        fi
    done
    
    echo "$project_id:$success_count/${#APIS_TO_ENABLE[@]}" >> "$PROGRESS_DIR/enabled_apis"
    echo "📋 项目 $project_id API启用完成 ($success_count/${#APIS_TO_ENABLE[@]})"
}

# 函数：创建单个服务账号
function create_service_account {
    local project_id=$1
    local prefix_chars=$2
    
    echo "👤 正在为项目 $project_id 创建服务账号..."
    
    # 设置当前项目
    gcloud config set project "$project_id" --quiet
    
    # 使用项目ID作为服务账号名称
    local sa_name="${project_id}"
    
    echo "  创建服务账号: $sa_name"
    
    # 创建服务账号
    if retry_command $MAX_RETRIES $BASE_RETRY_DELAY \
        "gcloud iam service-accounts create '$sa_name' --display-name='Vertex AI Service Account' --description='用于Vertex AI的服务账号' --project='$project_id' --quiet"; then
        
        local sa_email="${sa_name}@${project_id}.iam.gserviceaccount.com"
        echo "  ✓ 服务账号 $sa_name 创建成功"
        
        # 授予权限
        local role_success=0
        for role in "${SERVICE_ACCOUNT_ROLES[@]}"; do
            if retry_command $MAX_RETRIES $BASE_RETRY_DELAY \
                "gcloud projects add-iam-policy-binding '$project_id' --member='serviceAccount:$sa_email' --role='$role' --quiet"; then
                echo "    ✓ 角色 $role 授予成功"
                ((role_success++))
            else
                echo "    ❌ 角色 $role 授予失败"
            fi
        done
        
        echo "$project_id:$sa_email:$role_success" >> "$PROGRESS_DIR/service_accounts"
        echo "  🎯 项目 $project_id 服务账号配置完成 ($role_success/${#SERVICE_ACCOUNT_ROLES[@]} 角色)"
    else
        echo "  ❌ 服务账号 $sa_name 创建失败"
        echo "$project_id:failed" >> "$PROGRESS_DIR/failed_service_accounts"
    fi
}

# 函数：下载服务账号密钥（不上传，等待批量处理）
function download_keys_for_project {
    local project_id=$1
    local project_name=$2
    
    echo "🔑 正在下载项目 $project_id 的服务账号密钥..."
    
    # 设置当前项目
    gcloud config set project "$project_id" --quiet
    
    # 服务账号信息
    local sa_name="${project_id}"
    local sa_email="${sa_name}@${project_id}.iam.gserviceaccount.com"
    
    echo "  处理服务账号: $sa_name"
    
    # 下载项目密钥文件（使用项目名称作为文件名）
    local key_filename="${project_name}.json"
    local downloaded_count=0
    
    # 下载密钥文件
    if retry_command $MAX_RETRIES $BASE_RETRY_DELAY \
        "gcloud iam service-accounts keys create '$key_filename' --iam-account='$sa_email' --quiet"; then
        echo "    ✓ 密钥文件 $key_filename 下载成功"
        downloaded_count=1
    else
        echo "    ❌ 密钥文件 $key_filename 下载失败"
    fi
    
    echo "$project_id:$project_name:$downloaded_count:0" >> "$PROGRESS_DIR/key_results"
    echo "  📊 项目 $project_id ($project_name) 密钥下载完成 ($downloaded_count/1)"
}

# 函数：上传JSON文件到管理系统
function upload_project_files {
    local project_id=$1
    local project_name=$2
    
    if [ -z "$UPLOAD_API_URL" ]; then
        echo "    ⚠️  未配置上传API地址，跳过上传"
        return 1
    fi
    
    # 检查文件是否存在
    local filename="${project_name}.json"
    if [ ! -f "$filename" ]; then
        echo "    ⚠️  项目 $project_id 的文件 $filename 不存在，跳过上传"
        return 1
    fi
    
    local curl_cmd="curl -s"
    
    # 如果有token，添加认证头
    if [ ! -z "$UPLOAD_API_TOKEN" ]; then
        curl_cmd="$curl_cmd -H 'Authorization: Bearer $UPLOAD_API_TOKEN'"
    fi
    
    # 构建单文件上传命令
    curl_cmd="$curl_cmd -X POST -F 'files=@$filename' '$UPLOAD_API_URL'"
    
    # 执行上传
    local response
    response=$(eval "$curl_cmd" 2>/dev/null)
    local exit_code=$?
    
    if [ $exit_code -eq 0 ]; then
        # 检查响应是否包含成功标志
        if echo "$response" | grep -q '"success".*true'; then
            echo "    ✓ 项目 $project_id 的文件上传成功"
            # 上传成功后删除本地文件
            rm -f "$filename"
            echo "    ✓ 本地文件 $filename 已清理"
            return 0
        else
            echo "    ❌ 上传API返回错误: $response"
            return 1
        fi
    else
        echo "    ❌ 上传请求失败"
        return 1
    fi
}

#####################################################
#                主要逻辑开始                        #
#####################################################

echo "===== GCP项目批量创建脚本（账单绑定跟踪版）====="
echo "项目创建数量: $PROJECT_COUNT"
echo "每项目服务账号数: 1"
echo "最大并发数: $MAX_PARALLEL_JOBS"
echo "重试次数: $MAX_RETRIES"
echo "项目ID生成: 由GCP自动生成（随机唯一ID）"
echo "项目名称: 使用邮箱前缀构建有意义名称"
if [ ! -z "$UPLOAD_API_URL" ]; then
    echo "JSON上传地址: $UPLOAD_API_URL"
else
    echo "JSON上传地址: 未配置（将保存到本地）"
fi
echo "使用方法: $0 [项目数量]"
show_separator

# 检查gcloud是否安装
if ! command -v gcloud &> /dev/null; then
    error_exit "未找到gcloud命令。请安装Google Cloud SDK。"
fi

# 检查是否已登录
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" &> /dev/null; then
    error_exit "您尚未登录Google Cloud。请运行 'gcloud auth login' 进行登录。"
fi

#####################################################
#           第一步：列出邮箱名字                      #
#####################################################

echo "📧 第一步：获取当前登录邮箱信息"
current_account=$(gcloud auth list --filter=status:ACTIVE --format="value(account)")
if [ -z "$current_account" ]; then
    error_exit "无法获取当前账号信息。"
fi

echo "当前登录邮箱: $current_account"

# 提取邮箱前缀用于命名
email_prefix=$(echo "$current_account" | cut -d'@' -f1)

# 清理邮箱前缀，使其符合GCP项目命名规范
# 1. 转换为小写
# 2. 移除点号和特殊字符
# 3. 将下划线替换为连字符
# 4. 移除开头和结尾的连字符
clean_prefix=$(echo "$email_prefix" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]//g' | sed 's/_/-/g' | sed 's/^-*//;s/-*$//')

# 如果清理后为空，使用默认前缀
if [ -z "$clean_prefix" ]; then
    clean_prefix="user"
fi

# 截取前7个字符作为项目前缀
if [ ${#clean_prefix} -ge 7 ]; then
    prefix_chars=${clean_prefix:0:7}
else
    # 如果邮箱前缀不足7个字符，用0123456补充
    prefix_chars=$clean_prefix
    fill_chars="0123456"
    while [ ${#prefix_chars} -lt 7 ]; do
        needed=$((7 - ${#prefix_chars}))
        prefix_chars="${prefix_chars}${fill_chars:0:$needed}"
    done
fi

# 再次清理截取后的前缀，确保不以连字符结尾
prefix_chars=$(echo "$prefix_chars" | sed 's/-*$//')

echo "提取的前缀字符: $prefix_chars"
show_separator

#####################################################
#      第二步：列出活跃账单的名字-账单号               #
#####################################################

echo "💳 第二步：获取活跃账单信息"
billing_accounts=$(gcloud billing accounts list --filter=OPEN=true --format="value(ACCOUNT_ID,DISPLAY_NAME)")

if [ -z "$billing_accounts" ]; then
    error_exit "未找到有效的账单账号。"
fi

echo "找到以下活跃账单:"
billing_accounts_array=()
billing_names_array=()

while IFS=$'\t' read -r account_id display_name; do
    echo "- $display_name ($account_id)"
    billing_accounts_array+=("$account_id")
    billing_names_array+=("$display_name")
done <<< "$billing_accounts"

show_separator

#####################################################
#       第三步：解绑账单目前绑定的项目                 #
#####################################################

echo "🔗 第三步：解绑账单当前绑定的项目（并发处理）"

# 并发处理不同账单的解绑操作
unlink_jobs=()
for billing_account in "${billing_accounts_array[@]}"; do
    echo "正在检查账单 $billing_account 绑定的项目..."
    
    # 获取绑定到此账单的项目
    linked_projects=$(gcloud billing projects list --billing-account="$billing_account" --format="value(PROJECT_ID)" 2>/dev/null)
    
    if [ -z "$linked_projects" ]; then
        echo "账单 $billing_account 没有绑定的项目"
    else
        echo "账单 $billing_account 绑定的项目:"
        while read -r project_id; do
            if [ ! -z "$project_id" ]; then
                echo "  - 准备解绑项目: $project_id"
                unlink_jobs+=("unlink_project '$project_id' '$billing_account'")
            fi
        done <<< "$linked_projects"
    fi
done

if [ ${#unlink_jobs[@]} -gt 0 ]; then
    echo "🚀 开始并发解绑 ${#unlink_jobs[@]} 个项目..."
    run_parallel $MAX_PARALLEL_JOBS "${unlink_jobs[@]}"
    
    # 统计解绑结果
    unlinked_count=0
    if [ -f "$PROGRESS_DIR/unlinked_projects" ]; then
        unlinked_count=$(wc -l < "$PROGRESS_DIR/unlinked_projects")
    fi
    echo "📊 解绑完成: $unlinked_count/${#unlink_jobs[@]} 个项目"
fi

echo "所有账单的项目解绑处理完成"
show_separator

#####################################################
#           第四步：新建指定数量的项目                 #
#####################################################

echo "🏗️  第四步：并发创建 $PROJECT_COUNT 个新项目"

# 生成项目名称前缀
project_name_prefix="${PROJECT_PREFIX_LETTER}-${prefix_chars}-${PROJECT_SUFFIX}"

echo "使用的项目名称前缀: $project_name_prefix"

# 准备并发创建项目
create_jobs=()
for i in $(seq 1 $PROJECT_COUNT); do
    formatted_num=$(printf "%02d" $i)
    project_name="${project_name_prefix}-${formatted_num}"
    create_jobs+=("create_project '$project_name'")
done

echo "🚀 开始并发创建项目..."
run_parallel $MAX_PARALLEL_JOBS "${create_jobs[@]}"

# 收集创建成功的项目
created_projects=()
project_names=()
if [ -f "$PROGRESS_DIR/created_projects" ]; then
    while IFS=':' read -r project_id project_name; do
        created_projects+=("$project_id")
        project_names+=("$project_name")
    done < "$PROGRESS_DIR/created_projects"
fi

# 统计结果
failed_count=0
if [ -f "$PROGRESS_DIR/failed_projects" ]; then
    failed_count=$(wc -l < "$PROGRESS_DIR/failed_projects")
fi

echo "📊 项目创建完成: ${#created_projects[@]} 个成功, $failed_count 个失败"
show_separator

#####################################################
#           第五步：为项目绑定账单                     #
#####################################################

echo "💰 第五步：为项目绑定账单"

billing_count=${#billing_accounts_array[@]}
if [ $billing_count -eq 0 ]; then
    echo "⚠️  警告: 没有可用的账单账号，跳过账单绑定"
elif [ ${#created_projects[@]} -eq 0 ]; then
    echo "⚠️  警告: 没有成功创建的项目，跳过账单绑定"
else
    # 准备账单绑定任务
    billing_jobs=()
    for i in "${!created_projects[@]}"; do
        project_id=${created_projects[$i]}
        # 循环使用账单账号
        billing_index=$((i % billing_count))
        billing_account=${billing_accounts_array[$billing_index]}
        billing_name=${billing_names_array[$billing_index]}
        
        billing_jobs+=("link_billing '$project_id' '$billing_account' '$billing_name'")
    done
    
    echo "🚀 开始并发绑定账单..."
    run_parallel $MAX_PARALLEL_JOBS "${billing_jobs[@]}"
    
    # 统计绑定结果
    linked_count=0
    failed_billing_count=0
    if [ -f "$PROGRESS_DIR/linked_billing" ]; then
        linked_count=$(wc -l < "$PROGRESS_DIR/linked_billing")
    fi
    if [ -f "$PROGRESS_DIR/failed_billing" ]; then
        failed_billing_count=$(wc -l < "$PROGRESS_DIR/failed_billing")
    fi
    
    echo "📊 账单绑定完成: $linked_count 个成功, $failed_billing_count 个失败"

    # 收集成功绑定账单的项目
    SUCCESSFULLY_BILLED_PROJECTS=()
    if [ -f "$PROGRESS_DIR/linked_billing" ]; then
        while IFS=':' read -r project_id billing_account; do
            SUCCESSFULLY_BILLED_PROJECTS+=("$project_id")
        done < "$PROGRESS_DIR/linked_billing"
    fi

    echo "✅ 成功绑定账单的项目数量: ${#SUCCESSFULLY_BILLED_PROJECTS[@]}"
    echo "📋 后续操作将仅针对这 ${#SUCCESSFULLY_BILLED_PROJECTS[@]} 个成功绑定账单的项目进行"
fi

show_separator

#####################################################
#           第六步：为每个项目启用必要的API            #
#####################################################

echo "🔧 第六步：为每个项目启用必要的API服务（并发处理）"

if [ ${#SUCCESSFULLY_BILLED_PROJECTS[@]} -eq 0 ]; then
    echo "⚠️  警告: 没有成功绑定账单的项目，跳过API启用"
else
    # 准备API启用任务（仅针对成功绑定账单的项目）
    api_jobs=()
    for project_id in "${SUCCESSFULLY_BILLED_PROJECTS[@]}"; do
        api_jobs+=("enable_apis '$project_id'")
    done

    echo "🎯 仅为 ${#SUCCESSFULLY_BILLED_PROJECTS[@]} 个成功绑定账单的项目启用API"
    
    echo "🚀 开始并发启用API服务..."
    run_parallel $MAX_PARALLEL_JOBS "${api_jobs[@]}"
    
    # 统计API启用结果
    if [ -f "$PROGRESS_DIR/enabled_apis" ]; then
        echo "📊 API启用统计:"
        while IFS=':' read -r project_id result; do
            echo "  - $project_id: $result APIs 启用"
        done < "$PROGRESS_DIR/enabled_apis"
    fi
fi

show_separator

#####################################################
#     第七步：创建服务账号并授予Vertex AI权限          #
#####################################################

echo "👤 第七步：为每个项目创建服务账号并授予权限（并发处理）"

if [ ${#SUCCESSFULLY_BILLED_PROJECTS[@]} -eq 0 ]; then
    echo "⚠️  警告: 没有成功绑定账单的项目，跳过服务账号创建"
else
    # 准备服务账号创建任务（仅针对成功绑定账单的项目）
    sa_jobs=()
    for project_id in "${SUCCESSFULLY_BILLED_PROJECTS[@]}"; do
        sa_jobs+=("create_service_account '$project_id' '$prefix_chars'")
    done

    echo "🎯 仅为 ${#SUCCESSFULLY_BILLED_PROJECTS[@]} 个成功绑定账单的项目创建服务账号"
    
    echo "🚀 开始并发创建服务账号..."
    run_parallel $MAX_PARALLEL_JOBS "${sa_jobs[@]}"
    
    # 统计服务账号创建结果
    sa_success_count=0
    if [ -f "$PROGRESS_DIR/service_accounts" ]; then
        sa_success_count=$(wc -l < "$PROGRESS_DIR/service_accounts")
    fi
    
    echo "📊 服务账号创建完成: $sa_success_count 个"
fi

show_separator

#####################################################
#       第八步：下载服务账号密钥并上传到管理系统       #
#####################################################

echo "🔑 第八步：下载服务账号密钥并上传到管理系统（并发处理）"

if [ ${#SUCCESSFULLY_BILLED_PROJECTS[@]} -eq 0 ]; then
    echo "⚠️  警告: 没有成功绑定账单的项目，跳过密钥处理"
else
    # 准备密钥处理任务（仅针对成功绑定账单的项目）
    key_jobs=()

    # 需要找到成功绑定账单项目对应的项目名称
    for project_id in "${SUCCESSFULLY_BILLED_PROJECTS[@]}"; do
        # 从创建的项目列表中找到对应的项目名称
        for i in "${!created_projects[@]}"; do
            if [ "${created_projects[$i]}" = "$project_id" ]; then
                project_name=${project_names[$i]}
                key_jobs+=("download_keys_for_project '$project_id' '$project_name'")
                break
            fi
        done
    done

    echo "🎯 仅为 ${#SUCCESSFULLY_BILLED_PROJECTS[@]} 个成功绑定账单的项目处理密钥"
    
    echo "🚀 开始并发处理密钥文件..."
    run_parallel $MAX_PARALLEL_JOBS "${key_jobs[@]}"
    
    # 统计密钥处理结果
    total_downloaded=0
    total_uploaded=0
    if [ -f "$PROGRESS_DIR/key_results" ]; then
        echo "📊 密钥处理统计:"
        while IFS=':' read -r project_id project_name downloaded uploaded; do
            echo "  - $project_name ($project_id): 下载 $downloaded, 上传 $uploaded"
            total_downloaded=$((total_downloaded + downloaded))
            total_uploaded=$((total_uploaded + uploaded))
        done < "$PROGRESS_DIR/key_results"
    fi
    
    echo "📊 密钥处理完成: 总下载 $total_downloaded 个, 总上传 $total_uploaded 个"
    
    # 批量上传密钥文件到管理系统
    if [ ! -z "$UPLOAD_API_URL" ]; then
        echo ""
        echo "📤 开始批量上传密钥文件到管理系统..."
        
        uploaded_projects=0
        failed_uploads=0
        
        # 仅上传成功绑定账单的项目
        for project_id in "${SUCCESSFULLY_BILLED_PROJECTS[@]}"; do
            # 找到对应的项目名称
            project_name=""
            for i in "${!created_projects[@]}"; do
                if [ "${created_projects[$i]}" = "$project_id" ]; then
                    project_name=${project_names[$i]}
                    break
                fi
            done

            if [ ! -z "$project_name" ] && upload_project_files "$project_id" "$project_name"; then
                ((uploaded_projects++))
                # 更新统计
                if [ -f "$PROGRESS_DIR/key_results" ]; then
                    # 更新上传状态：project_id:project_name:downloaded:uploaded
                    sed -i "s/${project_id}:${project_name}:\([0-9]*\):0/${project_id}:${project_name}:\1:1/" "$PROGRESS_DIR/key_results"
                fi
            else
                ((failed_uploads++))
                # 记录失败的文件
                echo "${project_name}.json" >> "$PROGRESS_DIR/local_keys"
            fi
        done
        
        echo "📊 批量上传完成: $uploaded_projects 个项目成功, $failed_uploads 个项目失败"
        
        # 显示保留的本地文件
        if [ -f "$PROGRESS_DIR/local_keys" ] && [ -s "$PROGRESS_DIR/local_keys" ]; then
            echo "📁 以下密钥文件保留在本地（上传失败）:"
            while read -r key_file; do
                echo "  - $key_file"
            done < "$PROGRESS_DIR/local_keys"
        fi
    else
        echo "📁 所有密钥文件已下载到本地（未配置上传地址）"
    fi
fi

show_separator

#####################################################
#                 最终总结报告                        #
#####################################################

echo "===== 脚本执行完成总结 ====="
echo ""
echo "📧 登录邮箱: $current_account"
echo "⏱️  执行配置: 最大并发 $MAX_PARALLEL_JOBS, 重试次数 $MAX_RETRIES"
echo ""
echo "💳 使用的账单账号:"
for i in "${!billing_accounts_array[@]}"; do
    echo "  $((i+1)). ${billing_names_array[$i]} (${billing_accounts_array[$i]})"
done
echo ""
echo "📁 项目处理结果:"
echo "  - 成功创建: ${#created_projects[@]} 个项目"
echo "  - 成功绑定账单: ${#SUCCESSFULLY_BILLED_PROJECTS[@]} 个项目"
if [ ${#created_projects[@]} -gt 0 ]; then
    for i in "${!created_projects[@]}"; do
        project_id=${created_projects[$i]}
        project_name=${project_names[$i]}
        billing_index=$((i % ${#billing_accounts_array[@]}))
        if [ ${#billing_accounts_array[@]} -gt 0 ]; then
            billing_name=${billing_names_array[$billing_index]}
            echo "    $((i+1)). $project_name (ID: $project_id) (绑定账单: $billing_name)"
        else
            echo "    $((i+1)). $project_name (ID: $project_id) (未绑定账单)"
        fi
    done
fi

# 显示失败的项目
if [ -f "$PROGRESS_DIR/failed_projects" ] && [ -s "$PROGRESS_DIR/failed_projects" ]; then
    echo "  - 创建失败的项目:"
    while read -r project_id; do
        echo "    ❌ $project_id"
    done < "$PROGRESS_DIR/failed_projects"
fi

echo ""
echo "👤 服务账号创建结果:"
echo "  - 每个成功绑定账单的项目创建: 1 个服务账号"
echo "  - 预期总数: ${#SUCCESSFULLY_BILLED_PROJECTS[@]} 个"
if [ -f "$PROGRESS_DIR/service_accounts" ]; then
    actual_count=$(wc -l < "$PROGRESS_DIR/service_accounts")
    echo "  - 实际创建: $actual_count 个"
fi

echo ""
echo "🔑 密钥文件处理结果:"
if [ -f "$PROGRESS_DIR/key_results" ]; then
    total_downloaded=0
    total_uploaded=0
    while IFS=':' read -r project_id project_name downloaded uploaded; do
        total_downloaded=$((total_downloaded + downloaded))
        total_uploaded=$((total_uploaded + uploaded))
    done < "$PROGRESS_DIR/key_results"
    echo "  - 总下载: $total_downloaded 个密钥文件"
    echo "  - 成功上传到管理系统: $total_uploaded 个"
    echo "  - 保留本地: $((total_downloaded - total_uploaded)) 个"
else
    echo "  - 没有处理任何密钥文件"
fi

echo ""
echo "📊 整体执行统计:"
echo "  - 目标项目数量: $PROJECT_COUNT"
echo "  - 实际创建数量: ${#created_projects[@]}"
echo "  - 成功绑定账单数量: ${#SUCCESSFULLY_BILLED_PROJECTS[@]}"
echo "  - 项目创建成功率: $(( ${#created_projects[@]} * 100 / PROJECT_COUNT ))%"
if [ ${#created_projects[@]} -gt 0 ]; then
    echo "  - 账单绑定成功率: $(( ${#SUCCESSFULLY_BILLED_PROJECTS[@]} * 100 / ${#created_projects[@]} ))%"
fi

if [ -f "$PROGRESS_DIR/enabled_apis" ]; then
    total_apis=$(( ${#SUCCESSFULLY_BILLED_PROJECTS[@]} * ${#APIS_TO_ENABLE[@]} ))
    enabled_apis=$(awk -F: '{split($2,a,"/"); sum+=a[1]} END {print sum+0}' "$PROGRESS_DIR/enabled_apis")
    if [ $total_apis -gt 0 ]; then
        echo "  - API启用成功率: $(( enabled_apis * 100 / total_apis ))% ($enabled_apis/$total_apis)"
    fi
fi

echo ""
echo "✅ 所有操作完成！"
echo "   ✓ 项目已创建，其中 ${#SUCCESSFULLY_BILLED_PROJECTS[@]} 个成功绑定账单"
echo "   ✓ API服务已为成功绑定账单的项目启用"
echo "   ✓ 每个成功绑定账单的项目创建了 1 个服务账号并授予Vertex AI权限"
if [ ! -z "$UPLOAD_API_URL" ]; then
    echo "   ✓ 密钥文件已下载并上传到管理系统"
else
    echo "   ✓ 密钥文件已下载到本地"
fi
echo ""
echo "💡 使用说明："
echo "  - 项目ID: 由GCP自动生成的随机唯一标识符"
echo "  - 项目名称: 基于登录邮箱前缀构建的有意义名称"
echo "  - 密钥文件命名格式：项目名称.json（规范命名）"
if [ ! -z "$UPLOAD_API_URL" ]; then
    echo "  - 成功上传的密钥文件已自动导入管理系统"
    echo "  - 上传失败的密钥文件保留在当前目录"
fi
echo ""
echo "📂 详细日志保存在: $PROGRESS_DIR"
echo "   如需查看详细执行结果，请检查该目录下的文件"
show_separator
