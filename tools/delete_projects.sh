#!/bin/bash

# GCP项目批量删除脚本
# 用于清理已关闭账单的绑定项目

set -e

# 默认并发数
CONCURRENCY=5
DRY_RUN=false

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--concurrency)
            CONCURRENCY="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            echo "用法: $0 [选项]"
            echo "选项:"
            echo "  -c, --concurrency NUM    并发删除数量 (默认: 5)"
            echo "  --dry-run               仅显示要删除的项目，不实际删除"
            echo "  -h, --help              显示帮助信息"
            exit 0
            ;;
        *)
            echo "未知选项: $1"
            exit 1
            ;;
    esac
done

echo "=== GCP项目批量删除工具 ==="
echo "并发数: $CONCURRENCY"
echo "预览模式: $DRY_RUN"
echo

# 获取当前账号邮箱
echo "1. 获取当前账号信息..."
CURRENT_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" | head -1)
if [ -z "$CURRENT_ACCOUNT" ]; then
    echo "错误: 未找到活跃的GCP账号，请先登录"
    exit 1
fi
echo "当前账号: $CURRENT_ACCOUNT"

# 获取计费账户
echo
echo "2. 获取计费账户..."
BILLING_ACCOUNT=$(gcloud beta billing accounts list --format="value(name)" | head -1)
if [ -z "$BILLING_ACCOUNT" ]; then
    echo "错误: 未找到计费账户"
    exit 1
fi
echo "计费账户: $BILLING_ACCOUNT"

# 获取绑定的项目
echo
echo "3. 获取已绑定的项目..."
PROJECTS=$(gcloud beta billing projects list --billing-account="$BILLING_ACCOUNT" --format="value(projectId)")

if [ -z "$PROJECTS" ]; then
    echo "未找到绑定到该计费账户的项目"
    exit 0
fi

PROJECT_COUNT=$(echo "$PROJECTS" | wc -l)
echo "找到 $PROJECT_COUNT 个绑定项目:"
echo "$PROJECTS" | sed 's/^/  - /'

# 确认操作
echo
if [ "$DRY_RUN" = true ]; then
    echo "=== 预览模式：以下项目将被删除 ==="
    echo "$PROJECTS" | sed 's/^/  ✗ /'
    exit 0
fi

read -p "确认删除以上所有项目？这个操作不可逆！(输入 'DELETE' 确认): " CONFIRM
if [ "$CONFIRM" != "DELETE" ]; then
    echo "操作已取消"
    exit 0
fi

# 创建删除函数
delete_project() {
    local project_id=$1
    echo "正在删除项目: $project_id"

    if gcloud projects delete "$project_id" --quiet 2>/dev/null; then
        echo "✓ 成功删除: $project_id"
    else
        echo "✗ 删除失败: $project_id"
    fi
}

# 导出函数以供xargs使用
export -f delete_project

# 开始批量删除
echo
echo "4. 开始批量删除项目 (并发数: $CONCURRENCY)..."
echo "$PROJECTS" | xargs -I {} -P "$CONCURRENCY" bash -c 'delete_project "$@"' _ {}

echo
echo "=== 删除完成 ==="
echo "请检查剩余项目:"
REMAINING=$(gcloud beta billing projects list --billing-account="$BILLING_ACCOUNT" --format="value(projectId)")
if [ -z "$REMAINING" ]; then
    echo "✓ 所有项目已删除完成"
else
    echo "⚠ 仍有以下项目未删除:"
    echo "$REMAINING" | sed 's/^/  - /'
fi
