#!/usr/bin/env bash
# Post-deploy smoke checks for playwright-reports-server v6.
# v6 differs from the old app: /api/ping returns JSON {"status":"ok"} (not "pong"),
# and there is no /login page / Google-provider endpoint to assert on. Keep the
# checks minimal and auth-mode-agnostic: the public health endpoint + the SPA root.

set -euo pipefail

: "${APP_URL:?APP_URL is required}"

BASE="${APP_URL%/}"
MAX_ATTEMPTS="${SMOKE_MAX_ATTEMPTS:-18}"
SLEEP_SECONDS="${SMOKE_SLEEP_SECONDS:-10}"

echo "==> Smoke: GET ${BASE}/api/ping (expect HTTP 200)"
ok=""
for i in $(seq 1 "$MAX_ATTEMPTS"); do
  CODE=$(curl -s -o /tmp/ping.out -w "%{http_code}" "${BASE}/api/ping" || echo "000")
  if [ "$CODE" = "200" ]; then
    echo "ping ok (200): $(cat /tmp/ping.out)"
    ok=1
    break
  fi
  echo "attempt ${i}/${MAX_ATTEMPTS}: /api/ping http=${CODE}, retry in ${SLEEP_SECONDS}s"
  sleep "$SLEEP_SECONDS"
done
if [ -z "$ok" ]; then
  echo "::error::/api/ping did not return HTTP 200 after ${MAX_ATTEMPTS} attempts"
  exit 1
fi

echo "==> Smoke: GET ${BASE}/ (expect 2xx/3xx)"
ROOT=$(curl -s -o /dev/null -w "%{http_code}" "${BASE}/")
case "$ROOT" in
  2*|3*) echo "root ok (${ROOT})" ;;
  *) echo "::error::/ returned HTTP ${ROOT}, expected 2xx/3xx"; exit 1 ;;
esac

echo "smoke tests passed"
