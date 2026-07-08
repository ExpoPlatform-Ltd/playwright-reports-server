#!/usr/bin/env bash
# Register a new ECS task definition (same spec, new image) and roll out the service.
# Used by GitHub Actions deploy / rollback workflows.

set -euo pipefail

: "${AWS_REGION:?AWS_REGION is required}"
: "${ECS_CLUSTER:?ECS_CLUSTER is required}"
: "${ECS_SERVICE:?ECS_SERVICE is required}"
: "${IMAGE_URI:?IMAGE_URI is required}"

echo "==> Current task definition for ${ECS_SERVICE}"
CURRENT_ARN=$(aws ecs describe-services \
  --cluster "$ECS_CLUSTER" \
  --services "$ECS_SERVICE" \
  --region "$AWS_REGION" \
  --query 'services[0].taskDefinition' \
  --output text)

aws ecs describe-task-definition \
  --task-definition "$CURRENT_ARN" \
  --region "$AWS_REGION" \
  --query 'taskDefinition' \
  --output json \
  | jq \
    --arg IMG "$IMAGE_URI" \
    'del(
      .taskDefinitionArn,
      .revision,
      .status,
      .requiresAttributes,
      .compatibilities,
      .registeredAt,
      .registeredBy,
      .deregisteredAt,
      .enableFaultInjection
    )
    | .containerDefinitions |= map(if .name == "reports" then .image = $IMG else . end)' \
  > /tmp/playwright-reports-td.json

echo "==> Register task definition with image ${IMAGE_URI}"
OUT=$(aws ecs register-task-definition \
  --cli-input-json file:///tmp/playwright-reports-td.json \
  --region "$AWS_REGION" \
  --output json)

FAMILY=$(echo "$OUT" | jq -r '.taskDefinition.family')
REV=$(echo "$OUT" | jq -r '.taskDefinition.revision')
NEW_TD="${FAMILY}:${REV}"

echo "==> Update service → ${NEW_TD}"
aws ecs update-service \
  --cluster "$ECS_CLUSTER" \
  --service "$ECS_SERVICE" \
  --task-definition "$NEW_TD" \
  --force-new-deployment \
  --region "$AWS_REGION" \
  --query 'service.serviceName' \
  --output text

echo "==> Wait for stable rollout"
aws ecs wait services-stable \
  --cluster "$ECS_CLUSTER" \
  --services "$ECS_SERVICE" \
  --region "$AWS_REGION"

echo "task_definition=${NEW_TD}"
