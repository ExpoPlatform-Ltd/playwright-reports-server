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
metadata DB is corrupt. A plain redeploy will NOT fix it, and the safe recovery depends on the
storage backend (with no off-box replica, deleting the DB loses the index — preserve and repair
it instead). Doing this wrong can lose data. Use the `recover-db` workflow mode below, or follow
the team's internal DB-corruption recovery runbook (kept out of this public repo) — ask #devops.

## Recovering a corrupt metadata DB (`recover-db` mode)

GitHub → **Actions → "Deploy to ECS (non-prod)" → Run workflow**, set **mode = `recover-db`**
and **confirm = `recover`** (the confirm guard is required — this scales the service to 0 and
edits the DB).

What it does (`deploy/scripts/ecs-recover-db.sh`), safe by construction:

1. Reads the service's current desired count / task def / network config.
2. Scales the service to **0** (so no task holds the DB open — concurrent openers on EFS are
   the corruption vector).
3. Runs a **one-off task** on the same task definition (inherits the EFS volume), which backs
   up `metadata.db` → `.recover`s it into a new file → runs `PRAGMA integrity_check` → swaps
   the repaired DB in **only if it verifies clean**. The corrupt original is always kept as
   `metadata.db.corrupt.<ts>`.
4. Restores the service to its previous desired count (on success *or* failure) and runs the
   smoke check.

If `.recover` can't produce a clean DB the task exits non-zero, nothing is swapped, and the
workflow fails — then rebuild the index from the surviving blobs via `POST /api/admin/migrate-legacy`
(admin session; empty reports table). This deployment has **no off-box replica**, so there is no
"restore from S3/Azure" path.

**IAM:** the deploy role (`AWS_DEPLOY_ROLE_ARN`) needs `ecs:RunTask`, `ecs:DescribeTasks`,
`iam:PassRole` (task execution + task roles) and `logs:GetLogEvents`, in addition to the
`ecs:UpdateService`/`Describe*` it already uses. If `RunTask`/`PassRole` are missing the run
fails fast with a clear message; grant them and re-run.
