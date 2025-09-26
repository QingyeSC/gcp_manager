#!/bin/bash

# 并发创建GCP项目和Gemini API Key脚本
# 默认创建2个项目，并发执行，仅输出API Key

set -e

PROJECT_COUNT=2
TIMESTAMP=$(date +%s)

# 检查是否已登录
if ! gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -n1 > /dev/null; then
    exit 1
fi

# 获取账单账户
BILLING_ACCOUNT=$(gcloud beta billing accounts list --format="value(name)" --limit=1)
if [ -z "$BILLING_ACCOUNT" ]; then
    exit 1
fi

# 创建单个项目的函数
create_project() {
    local i=$1
    local project_id="gemini-project-${TIMESTAMP}-${i}"
    local api_key_name="gemini-key-$i"

    # 创建项目
    gcloud projects create $project_id --name="Gemini Project $i" --quiet >/dev/null 2>&1 || return 1

    # 设置当前项目
    gcloud config set project $project_id --quiet >/dev/null 2>&1

    # 绑定账单账户
    gcloud beta billing projects link $project_id --billing-account=$BILLING_ACCOUNT --quiet >/dev/null 2>&1 || return 1

    # 启用API服务
    gcloud services enable apikeys.googleapis.com --quiet >/dev/null 2>&1 || return 1
    gcloud services enable generativelanguage.googleapis.com --quiet >/dev/null 2>&1 || return 1

    # 创建API Key
    operation=$(gcloud services api-keys create --display-name="$api_key_name" --format="value(name)" 2>/dev/null) || return 1

    # 等待操作完成
    gcloud services operations wait "$operation" --quiet >/dev/null 2>&1 || return 1

    # 获取API Key
    key_name=$(gcloud services api-keys list --filter="displayName:$api_key_name" --format="value(name)" --limit=1 2>/dev/null)
    if [ -n "$key_name" ]; then
        api_key=$(gcloud services api-keys get-key-string "$key_name" --format="value(keyString)" 2>/dev/null)
        if [ -n "$api_key" ]; then
            echo "$api_key" > "key_${i}.tmp"
        fi
    fi
}

# 并发创建项目
for i in $(seq 1 $PROJECT_COUNT); do
    create_project $i &
done

# 等待所有后台任务完成
wait

# 合并所有临时key文件到key.txt
cat key_*.tmp > key.txt 2>/dev/null
rm -f key_*.tmp
