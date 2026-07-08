#!/usr/bin/env bash
# Post-deploy smoke checks for playwright-reports-server.

set -euo pipefail

: "${APP_URL:?APP_URL is required}"

BASE="${APP_URL%/}"
MAX_ATTEMPTS="${SMOKE_MAX_ATTEMPTS:-12}"
SLEEP_SECONDS="${SMOKE_SLEEP_SECONDS:-10}"

echo "==> Smoke: GET ${BASE}/api/ping"
for i in $(seq 1 "$MAX_ATTEMPTS"); do
  if BODY=$(curl -sf "${BASE}/api/ping" 2>/dev/null) && [ "$BODY" = "pong" ]; then
    echo "ping ok"
    break
  fi
  if [ "$i" -eq "$MAX_ATTEMPTS" ]; then
    echo "::error::/api/ping did not return pong after ${MAX_ATTEMPTS} attempts"
    exit 1
  fi
  echo "attempt ${i}/${MAX_ATTEMPTS}: retry in ${SLEEP_SECONDS}s"
  sleep "$SLEEP_SECONDS"
done

echo "==> Smoke: GET ${BASE}/api/auth/providers (Google OAuth registered)"
PROVIDERS=$(curl -sf "${BASE}/api/auth/providers")
echo "$PROVIDERS" | jq -e '.google.id == "google"' >/dev/null

echo "==> Smoke: GET ${BASE}/login (HTTP 200)"
STATUS=$(curl -s -o /dev/null -w "%{http_code}" "${BASE}/login")
if [ "$STATUS" != "200" ]; then
  echo "::error::/login returned HTTP ${STATUS}, expected 200"
  exit 1
fi

echo "smoke tests passed"
