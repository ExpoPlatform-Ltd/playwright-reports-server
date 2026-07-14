#!/usr/bin/env bash
# Post-deploy smoke checks for playwright-reports-server v6.
# v6 differs from the old app: /api/ping returns JSON {"status":"ok"} (not "pong"),
# and there is no /login page / Google-provider endpoint to assert on. Keep the
# base checks minimal and auth-mode-agnostic: the public health endpoint + the SPA root.
#
# IMPORTANT: /api/ping and / do NOT touch the SQLite metadata DB, so they stay green
# even when that DB is corrupt (SQLITE_CORRUPT) and every /api/report|result endpoint
# 500s. That gap once let a bad rollout ship "healthy". Set SMOKE_API_TOKEN (a key with
# the `view` capability; raw value, no "Bearer") to also assert a DB-backed endpoint —
# then corruption fails the deploy (and triggers rollback) instead of passing silently.
# Recovery steps live in the team's internal DB-corruption recovery runbook.

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

# DB-health check — only when a token is provided, so the base smoke stays auth-agnostic.
# A DB-backed endpoint returns 500 SQLITE_CORRUPT if the metadata.db is malformed; this
# turns that into a failed deploy (→ rollback) rather than a silently-green one.
if [ -n "${SMOKE_API_TOKEN:-}" ]; then
  echo "==> Smoke: GET ${BASE}/api/report/list?limit=1 (DB-backed, expect HTTP 200)"
  db_ok=""
  for i in $(seq 1 "$MAX_ATTEMPTS"); do
    CODE=$(curl -s -o /tmp/dbhealth.out -w "%{http_code}" \
      -H "Authorization: ${SMOKE_API_TOKEN}" \
      "${BASE}/api/report/list?limit=1" || echo "000")
    if [ "$CODE" = "200" ]; then
      echo "db ok (200)"
      db_ok=1
      break
    fi
    if [ "$CODE" = "401" ] || [ "$CODE" = "403" ]; then
      echo "::error::DB smoke got HTTP ${CODE} — SMOKE_API_TOKEN is missing the 'view' capability or is invalid. $(cat /tmp/dbhealth.out 2>/dev/null)"
      exit 1
    fi
    echo "attempt ${i}/${MAX_ATTEMPTS}: /api/report/list http=${CODE} body=$(cat /tmp/dbhealth.out 2>/dev/null), retry in ${SLEEP_SECONDS}s"
    sleep "$SLEEP_SECONDS"
  done
  if [ -z "$db_ok" ]; then
    echo "::error::DB-backed endpoint never returned 200 (last body: $(cat /tmp/dbhealth.out 2>/dev/null)). Likely SQLITE_CORRUPT — see the internal DB-corruption recovery runbook."
    exit 1
  fi
else
  echo "::warning::SMOKE_API_TOKEN not set — DB health NOT verified. A corrupt metadata.db would pass this smoke test. See the internal DB-corruption recovery runbook."
fi

echo "smoke tests passed"
