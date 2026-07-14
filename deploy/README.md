# ECS deploy (non-prod)

Deploys **v6** (the current monorepo `main`) to the non-prod ECS service.

Previously this pipeline built the `5.10.0-perf` branch (upstream 5.10 + EFS cache fixes).
That branch is now obsolete: upstream's v6 refactor already contains the equivalent fix
(process-global cache singleton) and replaced the in-memory report/result caches with a
SQLite layer, so the pipeline builds v6 directly.

## Deploy

GitHub → **Actions** → **Deploy to ECS (non-prod)** → **Run workflow** (on `main`).

The workflow checks out the dispatched ref, builds the v6 Docker image, pushes it to ECR,
registers a new ECS task definition, and rolls out the service. On smoke-test failure it
automatically rolls back to the previous task definition.

### Port

v6's image defaults to `PORT=3001`, but the deploy script pins the container's `PORT` env to
whatever `containerPort` the **existing** task definition already declares, so v6 keeps
listening on the port the target group expects (no target-group change needed).

## Secret

| Secret | Value |
|--------|-------|
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::933156343580:role/GitHubActionsPlaywrightReportsDeploy` |
| `SMOKE_API_TOKEN` *(optional)* | A `view`-capable API key (raw value). Enables the DB-health smoke check — see below. |

## Smoke checks

`deploy/scripts/smoke-test.sh` — `GET /api/ping` returns HTTP 200 (v6 returns JSON
`{"status":"ok"}`), and `GET /` returns 2xx/3xx.

⚠️ `/api/ping` and `/` do **not** touch the SQLite metadata DB, so they stay green even when
that DB is corrupt (`SQLITE_CORRUPT`) and every report/result endpoint 500s. Set the optional
`SMOKE_API_TOKEN` secret so the smoke test also asserts a DB-backed endpoint returns 200 —
then corruption fails the deploy (and rolls back) instead of shipping silently green.

## Troubleshooting

**`SQLITE_CORRUPT` / "database disk image is malformed" on report/result endpoints** — the
metadata DB is corrupt. A plain redeploy will NOT fix it (boot only restores from S3 when the
local DB is absent, so the corrupt file must be removed on the EFS mount first). Recovery
steps live in the team's internal DB-corruption recovery runbook (kept out of this public
repo) — ask #devops.
