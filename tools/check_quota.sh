#!/usr/bin/env bash
set -euo pipefail

# ========== 0) 读取当前项目 ==========
PROJECT_ID="$(gcloud config get-value project 2>/dev/null || true)"
if [ -z "${PROJECT_ID}" ]; then
  echo "❌ 未检测到默认项目。先执行：gcloud config set project <PROJECT_ID>"
  exit 1
fi

# ========== 1) 参数 ==========
MODEL="${MODEL:-gemini-2.5-flash}"     # 例：gemini-2.5-flash / gemini-2.5-pro / gemini-2.0-flash-001
RPM="${RPM:-120}"                      # 每分钟请求数
DURATION_SEC="${DURATION_SEC:-30}"     # 压测时长
CONCURRENCY="${CONCURRENCY:-20}"       # 并发上限
BODY='{"contents":[{"role":"user","parts":[{"text":"ping"}]}],"generationConfig":{"maxOutputTokens":16,"temperature":0.2}}'

# ========== 2) 检测并开启 Vertex AI API ==========
if ! gcloud services list --enabled --format="value(config.name)" \
  | grep -q "^aiplatform.googleapis.com$"; then
  echo "🔌 未开启 Vertex AI API，正在启用…"
  gcloud services enable aiplatform.googleapis.com
  echo "✅ Vertex AI API 已启用"
fi

# ========== 3) 凭据自检 ==========
ACCESS_TOKEN="$(gcloud auth print-access-token 2>/dev/null || true)"
if [ -z "${ACCESS_TOKEN}" ]; then
  echo "❌ 无可用访问令牌。请先执行：gcloud auth application-default login"
  exit 1
fi

# ========== 4) 组装 Global Endpoint URL ==========
URL="https://aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/global/publishers/google/models/${MODEL}:generateContent"

# ========== 5) 打印计划 ==========
printf "Project=%s  Endpoint=global  Model=%s\n" "$PROJECT_ID" "$MODEL"
echo "Target: ${RPM} RPM (~$(awk -v rpm="${RPM}" 'BEGIN{printf "%.2f", rpm/60.0}') RPS), Duration=${DURATION_SEC}s, Concurrency cap=${CONCURRENCY}"
echo "URL: ${URL}"

# ========== 6) 预检请求 ==========
PRE_STATUS="$(curl -s -o /tmp/_pre_body.txt -w "%{http_code}" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -X POST "${URL}" --data "${BODY}" 2>/dev/null || echo "000")"
echo "Preflight HTTP=${PRE_STATUS}"
if [ "${PRE_STATUS}" != "200" ]; then
  # 打印部分错误信息帮助定位
  echo "Preflight response (truncated):"
  head -c 300 /tmp/_pre_body.txt || true
  echo
fi

# ========== 7) 压测（限速=RPM，平滑发流） ==========
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
    code="$(curl -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      -H "Content-Type: application/json" \
      -X POST "${URL}" \
      --data "${BODY}" 2>/dev/null || echo "000")"
    echo "${code}" >> "${TMP_CODES}"
  ) &

  sleep "${INTERVAL}"
done
wait || true

# ========== 8) 统计（对空安全） ==========
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

# 友好提示
if [ "${total}" -eq 0 ] || [ "${ok}" -eq 0 ]; then
  echo "⚠️ 若持续 404/403/401："
  echo "  - 确认模型名对（如 gemini-2.5-flash / gemini-2.5-pro / gemini-2.0-flash-001）"
  echo "  - 你的项目是否已开通该模型的访问（组织/国家策略也可能拦截）"
  echo "  - 令牌有效：gcloud auth application-default login"
fi
