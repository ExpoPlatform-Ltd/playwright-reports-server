# Deploy (AWS ECS non-prod)

Branch **`5.10.0-perf`** — upstream `5.10.0` + cache/startup performance fixes for EFS-backed storage.

**URL:** https://playwright-reports.eu-west-1.ep-non-production.expoplatform.net  
**AWS account:** `933156343580`, region `eu-west-1`

## One-button deploy

GitHub → **Actions** → **Deploy to ECS (non-prod)** → **Run workflow** (branch `5.10.0-perf`).

## GitHub secret

| Secret | Value |
|--------|-------|
| `AWS_DEPLOY_ROLE_ARN` | `arn:aws:iam::933156343580:role/GitHubActionsPlaywrightReportsDeploy` |

IAM trust must include `repo:ExpoPlatform-Ltd/playwright-reports-server:*`.

## Cache fixes (this branch)

| File | Change |
|------|--------|
| `app/lib/service/lifecycle.ts` | result cache in background; `isInitializing()` |
| `app/lib/service/cache/reports.ts` | lightweight EFS init, retry, process-global singleton |
| `app/lib/service/cache/results.ts` | empty init, singleton |
| `app/lib/service/index.ts` | `ensureInitialized()` on APIs |
| `app/lib/storage/fs.ts` | skip `getFolderSize` in lightweight mode |

`main` tracks upstream **v6** (new architecture). Production deploys from **`5.10.0-perf`** until v6 migration.
