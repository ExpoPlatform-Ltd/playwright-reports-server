#!/usr/bin/env bash
# Point ECS service back to a previous task definition revision (no rebuild).

set -euo pipefail

: "${AWS_REGION:?AWS_REGION is required}"
: "${ECS_CLUSTER:?ECS_CLUSTER is required}"
: "${ECS_SERVICE:?ECS_SERVICE is required}"
: "${TASK_DEFINITION_ARN:?TASK_DEFINITION_ARN is required}"

echo "==> Roll back ${ECS_SERVICE} → ${TASK_DEFINITION_ARN}"
aws ecs update-service \
  --cluster "$ECS_CLUSTER" \
  --service "$ECS_SERVICE" \
  --task-definition "$TASK_DEFINITION_ARN" \
  --force-new-deployment \
  --region "$AWS_REGION" \
  --query 'service.serviceName' \
  --output text

echo "==> Wait for stable rollout"
aws ecs wait services-stable \
  --cluster "$ECS_CLUSTER" \
  --services "$ECS_SERVICE" \
  --region "$AWS_REGION"

echo "task_definition=${TASK_DEFINITION_ARN}"
