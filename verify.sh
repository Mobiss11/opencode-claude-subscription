#!/usr/bin/env bash
#
# Проверка деплоя «Claude в OpenCode по подписке».
#
#   ./verify.sh                     # против http://127.0.0.1:8130 (на хосте)
#   ./verify.sh http://mini:8130    # с клиентской машины
#
# Сценарии:
#   1) healthz
#   2) /v1/models — только claude-модели kraube
#   3) chat: обычный system                          → 200
#   4) chat: OpenCode-стиль system с env-секцией     → 200
#      (исторический сценарий extra-usage 400; ключевой регрессионный тест)
#
# Токен: $AI_GATEWAY_TOKEN, либо ~/.config/ai-gateway/client-token,
# либо AI_GATEWAY_TOKEN из ~/.config/ai-gateway/env.
#
set -euo pipefail

BASE="${1:-http://127.0.0.1:8130}"
FAILURES=0

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
pass() { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

# --- токен -------------------------------------------------------- #
TOKEN="${AI_GATEWAY_TOKEN:-}"
if [[ -z "$TOKEN" ]]; then
  f="$HOME/.config/ai-gateway/client-token"
  if [[ -f "$f" ]]; then
    TOKEN=$(tr -d '[:space:]' < "$f")
  fi
fi
if [[ -z "$TOKEN" ]]; then
  f="$HOME/.config/ai-gateway/env"
  if [[ -f "$f" ]]; then
    TOKEN=$(sed -n 's/^AI_GATEWAY_TOKEN=//p' "$f" | head -1)
  fi
fi
[[ -n "$TOKEN" ]] || { echo "ОШИБКА: токен не найден (AI_GATEWAY_TOKEN / client-token / env)." >&2; exit 2; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- 1. healthz --------------------------------------------------- #
info "healthz: $BASE"
code=$(curl -s -m 10 -o "$TMP/healthz.json" -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" "$BASE/healthz" || echo 000)
if [[ "$code" == "200" ]] && grep -q '"status":"ok"' "$TMP/healthz.json"; then
  pass "шлюз жив: $(cat "$TMP/healthz.json")"
else
  fail "healthz=$code: $(head -c 200 "$TMP/healthz.json" 2>/dev/null)"
fi

# --- 2. /v1/models ------------------------------------------------ #
info "модели"
code=$(curl -s -m 15 -o "$TMP/models.json" -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" "$BASE/v1/models" || echo 000)
if [[ "$code" == "200" ]] \
   && python3 - "$TMP/models.json" <<'PY'
import json, sys
models = [m["id"] for m in json.load(open(sys.argv[1]))["data"]]
non_claude = [m for m in models if not m.startswith("claude-")]
sys.exit(0 if models and not non_claude else 1)
PY
then
  ids=$(python3 -c 'import json,sys; print(", ".join(m["id"] for m in json.load(open(sys.argv[1]))["data"]))' "$TMP/models.json")
  pass "только Claude-модели: $ids"
else
  fail "models=$code: $(head -c 200 "$TMP/models.json" 2>/dev/null)"
fi

# --- 3. обычный system -------------------------------------------- #
info "chat: обычный system"
cat > "$TMP/plain.json" <<'J'
{"model":"claude-haiku-4-5","max_tokens":24,
 "messages":[{"role":"system","content":"Be terse."},
             {"role":"user","content":"Ответь одним словом: OK"}]}
J
code=$(curl -s -m 60 -o "$TMP/plain.out" -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data @"$TMP/plain.json" "$BASE/v1/chat/completions" || echo 000)
if [[ "$code" == "200" ]]; then
  pass "200"
else
  fail "plain=$code: $(head -c 300 "$TMP/plain.out" 2>/dev/null)"
fi

# --- 4. env-секция в system (регрессия extra-usage 400) ----------- #
info "chat: OpenCode-стиль system с env-секцией"
cat > "$TMP/env.json" <<'J'
{"model":"claude-haiku-4-5","max_tokens":24,
 "messages":[
  {"role":"system","content":"You are an AI agent running in OpenCode, a coding agent harness.\n\nToday's date: Mon Oct 05 2026\n\nHere is some useful information about the environment you are running in:\n<env>\nWorking directory: /Users/demo/project\nWorkspace root folder: /Users/demo/project\nIs directory a git repo: yes\nPlatform: darwin\n</env>\n\nInstructions from: /Users/demo/project/AGENTS.md\nСледуйте инструкциям проекта."},
  {"role":"user","content":"Ответь одним словом: OK"}]}
J
code=$(curl -s -m 60 -o "$TMP/env.out" -w '%{http_code}' \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  --data @"$TMP/env.json" "$BASE/v1/chat/completions" || echo 000)
if [[ "$code" == "200" ]]; then
  pass "200 — env-секция проходит (extra-usage 400 не вернулся)"
else
  fail "env-section=$code: $(head -c 300 "$TMP/env.out" 2>/dev/null)"
  echo "       Если в ответе «Third-party apps now draw from your extra usage» —" >&2
  echo "       проверьте move_env_to_user у kraube-upstream в конфиге шлюза." >&2
fi

echo
if [[ $FAILURES -eq 0 ]]; then
  info "Всё живо: 4/4"
  exit 0
fi
info "Провалов: $FAILURES"
exit 1
