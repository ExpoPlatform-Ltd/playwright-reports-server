#!/usr/bin/env bash
# Recover a corrupt SQLite metadata.db on the reports-server ECS task's EFS volume.
#
# This deployment runs DATA_STORAGE=fs with NO off-box replica, so the EFS metadata.db
# is the only copy — it must be REPAIRED, never deleted. This script is safe by design:
#
#   1. capture the service's current desired count / task def / network config
#   2. scale the service to 0 and wait — so no task holds the DB open (concurrent openers
#      on EFS are the corruption vector), leaving exactly one writer
#   3. run a ONE-OFF task on the same task definition (inherits the EFS volume + mount),
#      command overridden to: back up metadata.db -> `.recover` into a NEW file ->
#      `PRAGMA integrity_check` -> swap in ONLY if it reports "ok"
#   4. always restore the service to its previous desired count (trap on EXIT), whatever
#      the repair outcome
#
# The original corrupt file is always preserved as metadata.db.corrupt.<ts>. If .recover
# cannot produce a clean DB the swap is skipped and the task exits non-zero (rebuild the
# index from blobs via POST /api/admin/migrate-legacy instead — see deploy/README.md).
#
# Required IAM on the deploy role (beyond what deploy/rollback already use):
#   ecs:RunTask, ecs:DescribeTasks, iam:PassRole (task execution + task roles),
#   and logs:GetLogEvents for the log dump. If ecs:RunTask/iam:PassRole are missing,
#   run-task returns no task and this script fails fast with a clear message.
set -euo pipefail

: "${AWS_REGION:?AWS_REGION is required}"
: "${ECS_CLUSTER:?ECS_CLUSTER is required}"
: "${ECS_SERVICE:?ECS_SERVICE is required}"
: "${CONTAINER_NAME:?CONTAINER_NAME is required}"

echo "==> Describing service ${ECS_SERVICE}"
SVC=$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
  --region "$AWS_REGION" --query 'services[0]' --output json)

ORIG_DESIRED=$(echo "$SVC" | jq -r '.desiredCount')
TASK_DEF=$(echo "$SVC" | jq -r '.taskDefinition')
NET=$(echo "$SVC" | jq -c '.networkConfiguration // empty')
LAUNCH=$(echo "$SVC" | jq -r '.launchType // empty')
CAP=$(echo "$SVC" | jq -c '.capacityProviderStrategy // empty')
PLATFORM=$(echo "$SVC" | jq -r '.platformVersion // empty')
# Never bring the service back to 0 — if it was already 0/empty, restore to 1.
if [ -z "$ORIG_DESIRED" ] || [ "$ORIG_DESIRED" = "null" ] || [ "$ORIG_DESIRED" = "0" ]; then
  ORIG_DESIRED=1
fi
echo "    desired=${ORIG_DESIRED} taskDef=${TASK_DEF} launch=${LAUNCH:-<capacity-provider>}"

restore_service() {
  echo "==> Restoring service ${ECS_SERVICE} to desired count ${ORIG_DESIRED}"
  aws ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" \
    --desired-count "$ORIG_DESIRED" --region "$AWS_REGION" >/dev/null 2>&1 || true
  aws ecs wait services-stable --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" \
    --region "$AWS_REGION" || true
}
trap restore_service EXIT

echo "==> Scaling service to 0 (release the DB file before repair)"
aws ecs update-service --cluster "$ECS_CLUSTER" --service "$ECS_SERVICE" \
  --desired-count 0 --region "$AWS_REGION" >/dev/null
aws ecs wait services-stable --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" --region "$AWS_REGION"

# Container-side repair. Runs in the app image (Alpine) which lacks a sqlite3 CLI, so it
# installs one. Exit codes: 3 = no DB, 4 = unrecoverable (no clean DB — NOT swapped),
# 5 = sqlite install failed (task needs egress to the apk repos).
read -r -d '' REPAIR <<'SH' || true
set -e
DIR=/app/data
cd "$DIR"
if [ ! -f metadata.db ]; then echo "[recover] no metadata.db at $DIR — nothing to repair"; exit 3; fi
STAMP=$(date +%s)
echo "[recover] backing up -> metadata.db.corrupt.$STAMP"
cp metadata.db "metadata.db.corrupt.$STAMP"
echo "[recover] installing sqlite CLI"
apk add --no-cache sqlite >/dev/null 2>&1 || { echo "[recover] apk add sqlite failed (no egress to apk repos?)"; exit 5; }
echo "[recover] integrity_check (original, informational):"
sqlite3 metadata.db "PRAGMA integrity_check;" 2>&1 | head -3 || true
echo "[recover] running .recover into metadata.recovered.db"
sqlite3 metadata.db ".recover" 2>/dev/null | sqlite3 metadata.recovered.db 2>/dev/null || true
if [ ! -s metadata.recovered.db ]; then echo "[recover] .recover produced no usable DB"; exit 4; fi
CHECK=$(sqlite3 metadata.recovered.db "PRAGMA integrity_check;" 2>&1 | head -1)
echo "[recover] integrity_check (recovered): $CHECK"
if [ "$CHECK" != "ok" ]; then echo "[recover] recovered DB is not clean — NOT swapping (corrupt file preserved)"; exit 4; fi
mv metadata.recovered.db metadata.db
rm -f metadata.db-wal metadata.db-shm
echo "[recover] SUCCESS — repaired metadata.db swapped in"
SH

echo "==> Building one-off repair task overrides"
OVERRIDES=$(jq -nc --arg cn "$CONTAINER_NAME" --arg script "$REPAIR" \
  '{containerOverrides:[{name:$cn, command:["/bin/sh","-c",$script]}]}')

RUN_ARGS=(--cluster "$ECS_CLUSTER" --task-definition "$TASK_DEF" --count 1
  --started-by "gha-recover-db" --group "recover-db"
  --overrides "$OVERRIDES" --region "$AWS_REGION")
if [ -n "$NET" ]; then RUN_ARGS+=(--network-configuration "$NET"); fi
if [ -n "$LAUNCH" ]; then
  RUN_ARGS+=(--launch-type "$LAUNCH")
  if [ "$LAUNCH" = "FARGATE" ] && [ -n "$PLATFORM" ]; then RUN_ARGS+=(--platform-version "$PLATFORM"); fi
elif [ -n "$CAP" ]; then
  RUN_ARGS+=(--capacity-provider-strategy "$CAP")
fi

echo "==> Running one-off repair task"
TASK_ARN=$(aws ecs run-task "${RUN_ARGS[@]}" --query 'tasks[0].taskArn' --output text 2>&1) || {
  echo "::error::run-task failed: ${TASK_ARN}"; exit 1; }
if [ -z "$TASK_ARN" ] || [ "$TASK_ARN" = "None" ]; then
  echo "::error::run-task returned no task — the deploy role likely lacks ecs:RunTask / iam:PassRole"; exit 1
fi
echo "    task: ${TASK_ARN}"

echo "==> Waiting for the repair task to stop"
aws ecs wait tasks-stopped --cluster "$ECS_CLUSTER" --tasks "$TASK_ARN" --region "$AWS_REGION"

DESC=$(aws ecs describe-tasks --cluster "$ECS_CLUSTER" --tasks "$TASK_ARN" \
  --region "$AWS_REGION" --query 'tasks[0]' --output json)
EXIT_CODE=$(echo "$DESC" | jq -r --arg cn "$CONTAINER_NAME" \
  '(.containers[] | select(.name==$cn) | .exitCode) // "null"')
STOPPED_REASON=$(echo "$DESC" | jq -r '.stoppedReason // ""')
echo "    exitCode=${EXIT_CODE} stoppedReason=${STOPPED_REASON}"

# Best-effort: surface the repair task's own log output in the Actions run.
LOG_GROUP=$(aws ecs describe-task-definition --task-definition "$TASK_DEF" --region "$AWS_REGION" \
  --query "taskDefinition.containerDefinitions[?name=='${CONTAINER_NAME}'].logConfiguration.options.\"awslogs-group\" | [0]" \
  --output text 2>/dev/null || true)
LOG_PREFIX=$(aws ecs describe-task-definition --task-definition "$TASK_DEF" --region "$AWS_REGION" \
  --query "taskDefinition.containerDefinitions[?name=='${CONTAINER_NAME}'].logConfiguration.options.\"awslogs-stream-prefix\" | [0]" \
  --output text 2>/dev/null || true)
TID=${TASK_ARN##*/}
if [ -n "$LOG_GROUP" ] && [ "$LOG_GROUP" != "None" ]; then
  echo "==> Repair task logs (${LOG_GROUP}):"
  aws logs get-log-events --log-group-name "$LOG_GROUP" \
    --log-stream-name "${LOG_PREFIX}/${CONTAINER_NAME}/${TID}" \
    --region "$AWS_REGION" --limit 100 --query 'events[].message' --output text 2>/dev/null \
    || echo "    (logs not available yet)"
fi

if [ "$EXIT_CODE" != "0" ]; then
  echo "::error::DB recovery task exited ${EXIT_CODE}. The corrupt DB is preserved as metadata.db.corrupt.*; nothing was swapped. Next: rebuild the index from blobs via POST /api/admin/migrate-legacy (see deploy/README.md). Service is being restored to desired count ${ORIG_DESIRED}."
  exit 1
fi

echo "==> DB recovery succeeded — service will be restored to desired count ${ORIG_DESIRED}"
