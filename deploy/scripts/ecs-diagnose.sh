#!/usr/bin/env bash
# Best-effort diagnosis of the current ECS service/deployment: rollout state,
# recent service events, stopped-task reasons, and container logs. Never fails
# the caller (all AWS calls are tolerant) — it only prints.

set -uo pipefail

: "${AWS_REGION:?}"
: "${ECS_CLUSTER:?}"
: "${ECS_SERVICE:?}"
TD_FAMILY="${TD_FAMILY:-playwright-reports-server}"
CONTAINER_NAME="${CONTAINER_NAME:-reports}"

echo "===== service deployments ====="
aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" --region "$AWS_REGION" \
  --query 'services[0].deployments[].{status:status,td:taskDefinition,desired:desiredCount,running:runningCount,pending:pendingCount,failed:failedTasks,rollout:rolloutState,reason:rolloutStateReason}' \
  --output table || true

echo "===== last 25 service events ====="
aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" --region "$AWS_REGION" \
  --query 'services[0].events[:25].message' --output text || true

echo "===== stopped tasks ====="
STOPPED=$(aws ecs list-tasks --cluster "$ECS_CLUSTER" --service-name "$ECS_SERVICE" \
  --desired-status STOPPED --region "$AWS_REGION" --query 'taskArns' --output text 2>/dev/null || true)
echo "stopped task arns: ${STOPPED:-<none>}"

LOG_GROUP=$(aws ecs describe-task-definition --task-definition "$TD_FAMILY" --region "$AWS_REGION" \
  --query "taskDefinition.containerDefinitions[?name=='${CONTAINER_NAME}'].logConfiguration.options.\"awslogs-group\" | [0]" --output text 2>/dev/null || true)
LOG_PREFIX=$(aws ecs describe-task-definition --task-definition "$TD_FAMILY" --region "$AWS_REGION" \
  --query "taskDefinition.containerDefinitions[?name=='${CONTAINER_NAME}'].logConfiguration.options.\"awslogs-stream-prefix\" | [0]" --output text 2>/dev/null || true)
echo "log group: ${LOG_GROUP:-<unknown>}  stream-prefix: ${LOG_PREFIX:-<unknown>}"

for T in $STOPPED; do
  echo "----- stopped task $T -----"
  aws ecs describe-tasks --cluster "$ECS_CLUSTER" --tasks "$T" --region "$AWS_REGION" \
    --query 'tasks[0].{stoppedReason:stoppedReason,stopCode:stopCode,td:taskDefinitionArn,containers:containers[].{name:name,lastStatus:lastStatus,exitCode:exitCode,reason:reason}}' \
    --output json 2>&1 || true
  TID="${T##*/}"
  if [ -n "${LOG_GROUP:-}" ] && [ "${LOG_GROUP}" != "None" ] && [ -n "${LOG_PREFIX:-}" ] && [ "${LOG_PREFIX}" != "None" ]; then
    STREAM="${LOG_PREFIX}/${CONTAINER_NAME}/${TID}"
    echo "--- container logs: ${LOG_GROUP} / ${STREAM} ---"
    aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$STREAM" \
      --region "$AWS_REGION" --limit 200 --start-from-head --query 'events[].message' --output text 2>&1 \
      | tail -200 || echo "(could not read logs — role may lack logs:GetLogEvents)"
  fi
done
