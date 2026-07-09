#!/usr/bin/env bash
# Register a new ECS task definition (new image, with the container's PORT env
# pinned to the port the task definition already declares) and roll out the
# service. Deriving PORT from the existing containerPort lets the v6 image
# (which defaults to 3001) slot into the current target group unchanged.

set -euo pipefail

: "${AWS_REGION:?AWS_REGION is required}"
: "${ECS_CLUSTER:?ECS_CLUSTER is required}"
: "${ECS_SERVICE:?ECS_SERVICE is required}"
: "${IMAGE_URI:?IMAGE_URI is required}"

CONTAINER_NAME="${CONTAINER_NAME:-reports}"

echo "==> Current task definition for ${ECS_SERVICE}"
CURRENT_ARN=$(aws ecs describe-services \
  --cluster "$ECS_CLUSTER" \
  --services "$ECS_SERVICE" \
  --region "$AWS_REGION" \
  --query 'services[0].taskDefinition' \
  --output text)
echo "current task definition: ${CURRENT_ARN}"

CURRENT_TD=$(aws ecs describe-task-definition \
  --task-definition "$CURRENT_ARN" \
  --region "$AWS_REGION" \
  --query 'taskDefinition' \
  --output json)

# Visibility only — names/ports/mounts, env keys only (no values, so no secret leakage).
echo "==> Existing container definitions"
echo "$CURRENT_TD" | jq '.containerDefinitions | map({
  name, image, portMappings, mountPoints,
  env_keys: (.environment // [] | map(.name)),
  secret_keys: (.secrets // [] | map(.name))
})'

echo "$CURRENT_TD" \
  | jq \
    --arg IMG "$IMAGE_URI" \
    --arg CN "$CONTAINER_NAME" \
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
    | .containerDefinitions |= map(
        if .name == $CN then
          (.portMappings[0].containerPort // 3000) as $cp
          | .image = $IMG
          | .environment = (
              (.environment // [])
              | map(select(.name != "PORT"))
              + [{name: "PORT", value: ($cp | tostring)}]
            )
        else . end)' \
  > /tmp/playwright-reports-td.json

# Safety: the image must actually be present on the target container, otherwise
# the container name is wrong and we would silently redeploy the old image.
if ! jq -e --arg IMG "$IMAGE_URI" --arg CN "$CONTAINER_NAME" \
     '.containerDefinitions[] | select(.name==$CN and .image==$IMG)' \
     /tmp/playwright-reports-td.json >/dev/null; then
  echo "::error::no container named '${CONTAINER_NAME}' found to update. Container names present:"
  jq -r '.containerDefinitions[].name' /tmp/playwright-reports-td.json
  exit 1
fi

echo "==> New container spec (image + PORT)"
jq --arg CN "$CONTAINER_NAME" \
  '.containerDefinitions[] | select(.name==$CN) | {name, image, portMappings, env_keys: (.environment // [] | map(.name))}' \
  /tmp/playwright-reports-td.json

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
