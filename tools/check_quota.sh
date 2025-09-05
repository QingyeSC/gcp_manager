#!/usr/bin/env bash
# 一体化：选择项目 + 启用API + Global端点压测
set -euo pipefail

# ===== 可通过环境变量覆盖的参数 =====
TARGET_BILLING_ACCOUNT="${TARGET_BILLING_ACCOUNT:-}"   # 指定账单（可选）
TARGET_PROJECT_ID="${TARGET_PROJECT_ID:-}"             # 指定项目（可选）
MODEL="${MODEL:-gemini-2.5-flash}"                     # 测试模型
RPM="${RPM:-120}"                                      # 每分钟请求数
DURATION_SEC="${DURATION_SEC:-30}"                     # 压测时长（秒）
CONCURRENCY="${CONCURRENCY:-20}"                       # 并发上限
BODY='{"contents":[{"role":"user","parts":[{"text":"ping"}]}],"generationConfig":{"maxOutputTokens":16,"temperature":0.2}}'

# ===== 工具函数 =====
abort() { echo "❌ $*" >&2; exit 1; }
info()  { echo -e "$*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || abort "缺少命令：$1"; }

# ===== 0) 依赖与登录检查 =====
need_cmd gcloud
need_cmd awk
need_cmd curl

ACTIVE_ACCOUNT="$(gcloud auth list --filter='status:ACTIVE' --format='value(account)' 2>/dev/null || true)"
[ -n "$ACTIVE_ACCOUNT" ] || abort "未检测到已登录账号，请先执行：gcloud auth login"

info "== 账号 ==\nActive account: ${ACTIVE_ACCOUNT}\n"

# ===== 1) 选择账单 =====
mapfile -t BILLINGS < <(gcloud beta billing accounts list --filter="open=true" --format="value(ACCOUNT_ID)" 2>/dev/null)
[ "${#BILLINGS[@]}" -gt 0 ] || abort "没有可用的活跃账单（open=true）。"

if [ -n "$TARGET_BILLING_ACCOUNT" ]; then
  CHOSEN_BA="$TARGET_BILLING_ACCOUNT"
  info "使用指定账单: ${CHOSEN_BA}"
elif [ "${#BILLINGS[@]}" -eq 1 ]; then
  CHOSEN_BA="${BILLINGS[0]}"
  info "检测到唯一账单: ${CHOSEN_BA}"
else
  info "发现多个账单："
  i=1; for ba in "${BILLINGS[@]}"; do echo "  [$i] $ba"; i=$((i+1)); done
  read -rp "请选择账单序号: " IDX
  [[ "$IDX" =~ ^[0-9]+$ ]] && [ "$IDX" -ge 1 ] && [ "$IDX" -le "${#BILLINGS[@]}" ] \
    || abort "无效选择"
  CHOSEN_BA="${BILLINGS[$((IDX-1))]}"
fi
echo

# ===== 2) 列出该账单绑定的项目并选择 =====
mapfile -t PROJS < <(gcloud beta billing projects list --billing-account="$CHOSEN_BA" --format="value(projectId)" 2>/dev/null)
[ "${#PROJS[@]}" -gt 0 ] || abort "该账单下没有绑定任何项目。"

if [ -n "$TARGET_PROJECT_ID" ]; then
  CHOSEN_PROJ="$TARGET_PROJECT_ID"
  info "使用指定项目: ${CHOSEN_PROJ}"
elif [ "${#PROJS[@]}" -eq 1 ]; then
  CHOSEN_PROJ="${PROJS[0]}"
  info "检测到唯一项目: ${CHOSEN_PROJ}"
else
  info "发现多个项目："
  i=1; for p in "${PROJS[@]}"; do echo "  [$i] $p"; i=$((i+1)); done
  read -rp "请选择项目序号: " PIDX
  [[ "$PIDX" =~ ^[0-9]+$ ]] && [ "$PIDX" -ge 1 ] && [ "$PIDX" -le "${#PROJS[@]}" ] \
    || abort "无效选择"
  CHOSEN_PROJ="${PROJS[$((PIDX-1))]}"
fi
echo

# ===== 3) 设置默认项目 & quota project =====
info "== 设置默认项目 & quota project =="
gcloud config set project "${CHOSEN_PROJ}" >/dev/null
gcloud auth application-default set-quota-project "${CHOSEN_PROJ}" >/dev/null || true
info "✅ 当前项目：${CHOSEN_PROJ}\n"

# ===== 4) 确保开通 Vertex AI API =====
if ! gcloud services list --enabled --format="value(config.name)" | grep -q "^aiplatform.googleapis.com$"; then
  info "🔌 启用 Vertex AI API ..."
  gcloud services enable aiplatform.googleapis.com
  info "✅ Vertex AI API 已启用\n"
fi

# ===== 5) 凭据检查 =====
ACCESS_TOKEN="$(gcloud auth print-access-token 2>/dev/null || true)"
[ -n "$ACCESS_TOKEN" ] || abort "无法获取访问令牌。请执行：gcloud auth application-default login"

# ===== 6) 组装 Global Endpoint URL =====
URL="https://aiplatform.googleapis.com/v1/projects/${CHOSEN_PROJ}/locations/global/publishers/google/models/${MODEL}:generateContent"

info "== 压测计划（global） =="
echo "Project=${CHOSEN_PROJ}"
echo "Model=${MODEL}"
echo "Target: ${RPM} RPM (~$(awk -v rpm="${RPM}" 'BEGIN{printf "%.2f", rpm/60.0}') RPS), Duration=${DURATION_SEC}s, Concurrency cap=${CONCURRENCY}"
echo "URL: ${URL}"
echo

# ===== 7) 预检 =====
PRE_STATUS="$(curl -s -o /tmp/_pre_body.txt -w '%{http_code}' \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -X POST "${URL}" --data "${BODY}" 2>/dev/null || echo '000')"
echo "Preflight HTTP=${PRE_STATUS}"
if [ "${PRE_STATUS}" != "200" ]; then
  echo "Preflight response (truncated):"
  head -c 300 /tmp/_pre_body.txt || true
  echo
fi

# ===== 8) 压测（1分钟默认，平滑限速） =====
INTERVAL="$(awk -v rpm="${RPM}" 'BEGIN{printf "%.3f", 60.0/rpm}')"
TMP_CODES="$(mktemp)"
trap 'rm -f "$TMP_CODES" /tmp/_pre_body.txt 2>/dev/null || true' EXIT

echo "Sending ..."
START_TS="$(date +%s)"
END_TS=$(( START_TS + DURATION_SEC ))

while [ "$(date +%s)" -lt "${END_TS}" ]; do
  while [ "$(jobs -rp | wc -l)" -ge "${CONCURRENCY}" ]; do
    wait -n || true
  done
  (
    code="$(curl -s -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -X POST "${URL}" --data "${BODY}" 2>/dev/null || echo '000')"
    echo "${code}" >> "${TMP_CODES}"
  ) &
  sleep "${INTERVAL}"
done
wait || true

# ===== 9) 统计（对空安全） =====
total=$( (wc -l < "${TMP_CODES}") 2>/dev/null | tr -d ' ' ); total=${total:-0}
ok=$(awk '/^2/{c++} END{print c+0}' "${TMP_CODES}" 2>/dev/null || echo 0)
r429=$(awk '$0==429{c++} END{print c+0}' "${TMP_CODES}" 2>/dev/null || echo 0)
fail=$(( total - ok ))
(( fail < 0 )) && fail=0

success_rate=$(awk -v t="${total}" -v o="${ok}" 'BEGIN{ if(t==0) print 0; else printf "%.1f", 100*o/t }')
r429_rate=$(awk -v t="${total}" -v r="${r429}" 'BEGIN{ if(t==0) print 0; else printf "%.1f", 100*r/t }')

echo
echo "===== Result (${DURATION_SEC}s, global) ====="
echo "Total sent: ${total}"
echo "2xx OK:     ${ok}"
echo "429:        ${r429}"
echo "Other fail: ${fail}"
echo "Success %:  ${success_rate}%"
echo "429 %:      ${r429_rate}%"

if [ "${total}" -eq 0 ] || [ "${ok}" -eq 0 ]; then
  echo "⚠️ 若持续 404/403/401："
  echo "  - 确认模型名（gemini-2.5-flash / gemini-2.5-pro / gemini-2.0-flash-001 / gemini-2.5-flash-lite / ...）"
  echo "  - 组织/位置策略可能限制 global；或项目未允许该模型"
  echo "  - 令牌问题：gcloud auth application-default login"
fi
