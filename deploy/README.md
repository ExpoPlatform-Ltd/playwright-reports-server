# ECS deploy (non-prod)

Production-like deploy uses branch **`5.10.0-perf`** (upstream 5.10.0 + EFS cache fixes).

**Do not merge `5.10.0-perf` into `main`.**  
`main` is upstream v6 (new monorepo architecture); the branches have unrelated app code.

## Deploy

GitHub → **Actions** → **Deploy to ECS (non-prod)** → **Run workflow** (on `main`).

The workflow checks out `5.10.0-perf` and builds from that branch.

## Secret

| Secret | Value |
|--------|-------|
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::933156343580:role/GitHubActionsPlaywrightReportsDeploy` |

## Cache fixes

See branch `5.10.0-perf` — `app/lib/service/cache/*.ts`, `lifecycle.ts`, etc.
