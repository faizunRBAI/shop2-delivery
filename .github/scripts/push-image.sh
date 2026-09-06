#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Build the ShopFast image and push it to ECR under an IMMUTABLE git-SHA tag.
#
# The repository has image_tag_mutability=IMMUTABLE, so a tag that already
# exists cannot be overwritten — that is what makes the GitOps reference in
# gitops/environments/production/shopfast-values.yaml trustworthy: the SHA
# always names exactly the bytes CI built.
#
# Usage: push-image.sh <git-sha>
# ---------------------------------------------------------------------------
set -Eeuo pipefail

GIT_SHA="${1:?usage: push-image.sh <git-sha>}"

: "${AWS_REGION:?AWS_REGION must be set}"
: "${TF_STATE_BUCKET:?TF_STATE_BUCKET must be set}"
: "${PROJECT_NAME:?PROJECT_NAME must be set}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# Read the registry from terraform state rather than reconstructing it from a
# name pattern (the project-name-derived value is masked in job outputs).
echo "==> Resolving the ECR repository from terraform state"
pushd infra >/dev/null
terraform init -input=false -reconfigure \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=${PROJECT_NAME}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" >/dev/null
ECR_REPO="$(terraform output -raw ecr_repository_url)"
popd >/dev/null

[ -n "$ECR_REPO" ] || { echo "ERROR: ecr_repository_url is empty" >&2; exit 1; }

REGISTRY="${ECR_REPO%%/*}"      # <account>.dkr.ecr.<region>.amazonaws.com
REPO_PATH="${ECR_REPO#*/}"      # <project>/shopfast

echo "==> Logging in to ${REGISTRY}"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

# Immutable tags make a re-run of the same commit a no-op rather than a failure.
if aws ecr describe-images \
     --repository-name "$REPO_PATH" \
     --image-ids "imageTag=${GIT_SHA}" \
     --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "==> ${ECR_REPO}:${GIT_SHA} already exists (immutable) — skipping the push"
  exit 0
fi

echo "==> Building ${ECR_REPO}:${GIT_SHA}"
docker build \
  --tag "${ECR_REPO}:${GIT_SHA}" \
  --label "org.opencontainers.image.revision=${GIT_SHA}" \
  --label "org.opencontainers.image.source=${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}" \
  application

echo "==> Pushing ${ECR_REPO}:${GIT_SHA}"
docker push "${ECR_REPO}:${GIT_SHA}"

echo "==> Verifying the pushed image exists in ECR"
aws ecr describe-images \
  --repository-name "$REPO_PATH" \
  --image-ids "imageTag=${GIT_SHA}" \
  --region "$AWS_REGION" \
  --query 'imageDetails[0].{digest:imageDigest,pushedAt:imagePushedAt,bytes:imageSizeInBytes}' \
  --output table

echo "==> Pushed ${ECR_REPO}:${GIT_SHA}"
