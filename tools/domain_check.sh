#!/bin/bash
set -euo pipefail

echo "=== Cloud Domains 配额自动检测 ==="
echo ""

### Step 1: 当前账号
ACCOUNT=$(gcloud config get-value account 2>/dev/null)
echo "=== Step 1: 获取当前登录账号 ==="
echo "当前登录账号: $ACCOUNT"
echo ""

### Step 2: 活跃账单账号
echo "=== Step 2: 获取活跃的账单账号 ==="
BILLING_ACCOUNT=$(gcloud beta billing accounts list --filter="open=true" --format="value(name)" | head -n 1)
if [ -z "$BILLING_ACCOUNT" ]; then
  echo "❌ 未找到活跃账单账号"
  exit 1
fi
echo "活跃账单账号: $BILLING_ACCOUNT"
echo ""

### Step 3: 检查现有项目
echo "=== Step 3: 检查现有项目 ==="
PROJECT_ID=$(gcloud projects list --format="value(projectId)" | head -n 1)
if [ -z "$PROJECT_ID" ]; then
  PROJECT_ID="auto-proj-$(date +%s)"
  echo "未找到项目，正在创建新项目: $PROJECT_ID"
  gcloud projects create "$PROJECT_ID" --name="Auto Domain Project"
  gcloud beta billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
else
  echo "找到项目: $PROJECT_ID"
fi
echo ""

### Step 4: 设置默认项目
echo "=== Step 4: 设置默认项目 ==="
gcloud config set project "$PROJECT_ID"
echo ""

### Step 5: 启用 Cloud Domains API
echo "=== Step 5: 启用 Cloud Domains API ==="
gcloud services enable domains.googleapis.com --project="$PROJECT_ID"
echo ""

### Step 6: 查询域名注册配额
echo "=== Step 6: 查询域名注册配额 ==="
PROJECT_NUM=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
TOKEN=$(gcloud auth print-access-token)

RESPONSE=$(curl -s -H "Authorization: Bearer $TOKEN" \
  "https://serviceusage.googleapis.com/v1/projects/$PROJECT_NUM/services/domains.googleapis.com")

if echo "$RESPONSE" | jq empty 2>/dev/null; then
    DOMAIN_QUOTA=$(echo "$RESPONSE" | jq -r '
      .config.quota.limits[] 
      | select(.name == "DomainRegistrationsPerProject") 
      | .values.DEFAULT' 2>/dev/null)

    if [ -n "$DOMAIN_QUOTA" ] && [ "$DOMAIN_QUOTA" != "null" ]; then
        echo "✅ 域名注册配额: $DOMAIN_QUOTA 个域名/项目"
    else
        echo "⚠️ 未找到域名注册配额 (请去 Console 确认)"
    fi
else
    echo "❌ 无法获取 Cloud Domains API 配额信息"
fi
