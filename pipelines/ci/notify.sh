#!/usr/bin/env bash
# ════════════════════════════════════════════════════════════════════════
#  notify.sh <SUCCESS|FAILURE|ABORTED|WARN> "<message>"        (used by every Jenkinsfile `post {}` block)
#  Posts one line to the team chat. Google Chat (the ✅REAL pattern) and Slack both accept {"text": "..."} on an incoming webhook.
#  Env : CHAT_WEBHOOK_URL (CI secret). Not set → just prints (so local runs and forks never fail because of chat).
# ════════════════════════════════════════════════════════════════════════
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
status="${1:?usage: notify.sh <STATUS> <message>}"; shift
msg="$*"

case "$status" in SUCCESS) icon="✅" ;; FAILURE) icon="❌" ;; ABORTED) icon="⛔" ;; *) icon="⚠️" ;; esac
line="$icon [$status] $msg  ·  ${BUILD_URL:-local-run}"
log "notify: $line"

[ -n "${CHAT_WEBHOOK_URL:-}" ] || exit 0
need curl jq
# jq builds the JSON, so quotes/newlines in the message can never break (or inject into) the payload
curl -fsS -m 15 -X POST -H 'Content-Type: application/json' -d "$(jq -n --arg t "$line" '{text:$t}')" "$CHAT_WEBHOOK_URL" >/dev/null \
  || warn "chat notification failed (the build result is NOT affected)"

# ════════════════════════════════════════════════════════════════════════
# EXPLAINED
#   best-effort on purpose      a chat outage must never turn a good deploy red, so every failure here is only a warning.
#   jq -n --arg t "$line"       --arg passes the text as a JSON string with correct escaping. Hand-building JSON with echo is how
#                               a quote in an error message becomes a broken request.
#   curl -fsS -m 15             -f fail on HTTP errors · -sS quiet but show errors · -m 15 give up after 15 s.
#   the webhook URL is a secret anyone holding it can post as the bot → a Jenkins credential, never in git.
# ════════════════════════════════════════════════════════════════════════
