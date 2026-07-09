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

echo "===== current task def: container healthCheck / command / ports ====="
aws ecs describe-task-definition --task-definition "$TD_FAMILY" --region "$AWS_REGION" \
  --query "taskDefinition.containerDefinitions[?name=='${CONTAINER_NAME}'].{healthCheck:healthCheck,command:command,entryPoint:entryPoint,portMappings:portMappings,essential:essential} | [0]" \
  --output json 2>&1 || true

echo "===== reports container environment (non-secret values) ====="
aws ecs describe-task-definition --task-definition "$TD_FAMILY" --region "$AWS_REGION" \
  --query "taskDefinition.containerDefinitions[?name=='${CONTAINER_NAME}'].environment | [0]" --output json 2>&1 || true

echo "===== logs by recent task-ids parsed from service events ====="
TASK_IDS=$(aws ecs describe-services --cluster "$ECS_CLUSTER" --services "$ECS_SERVICE" --region "$AWS_REGION" \
  --query 'services[0].events[:40].message' --output text 2>/dev/null \
  | grep -oE 'task [0-9a-f]{32}' | grep -oE '[0-9a-f]{32}' | awk '!seen[$0]++' | head -4 || true)
echo "task ids: ${TASK_IDS:-<none>}"
if [ -n "${LOG_GROUP:-}" ] && [ "${LOG_GROUP}" != "None" ] && [ -n "${LOG_PREFIX:-}" ] && [ "${LOG_PREFIX}" != "None" ]; then
  for TID in $TASK_IDS; do
    STREAM="${LOG_PREFIX}/${CONTAINER_NAME}/${TID}"
    echo "--- logs: ${LOG_GROUP} / ${STREAM} ---"
    aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$STREAM" \
      --region "$AWS_REGION" --limit 100 --start-from-head --query 'events[].message' --output text 2>&1 \
      | tail -100 || echo "(could not read logs — role may lack logs:GetLogEvents)"
  done
fi

echo "===== most recent log stream in ${LOG_GROUP} (likely the failing v6 task) ====="
if [ -n "${LOG_GROUP:-}" ] && [ "${LOG_GROUP}" != "None" ]; then
  RECENT=$(aws logs describe-log-streams --log-group-name "$LOG_GROUP" --region "$AWS_REGION" \
    --order-by LastEventTime --descending --limit 1 --query 'logStreams[0].logStreamName' --output text 2>/dev/null || true)
  echo "recent stream: ${RECENT:-<none>}"
  if [ -n "${RECENT:-}" ] && [ "${RECENT}" != "None" ]; then
    aws logs get-log-events --log-group-name "$LOG_GROUP" --log-stream-name "$RECENT" \
      --region "$AWS_REGION" --limit 200 --start-from-head --query 'events[].message' --output text 2>&1 \
      | tail -200 || echo "(could not read logs — role may lack logs:GetLogEvents)"
  fi
fi

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
