#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Cluster bootstrap — the ONLY imperative step in the whole platform.
#
# It installs the two components that cannot install themselves (the AWS Load
# Balancer Controller and Argo CD), seeds their credentials, materialises the
# account-specific values into the GitOps tree, and hands ownership of
# everything else to the App-of-Apps root Application. From that point on the
# cluster's desired state is whatever is committed under gitops/.
#
# NO credential value appears in this file. Credentials arrive as environment
# variables from GitHub Secrets and are piped to kubectl on stdin — never as
# command-line arguments, which are world-readable via `ps` on the runner.
#
# Idempotent: safe to re-run on every deploy.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

: "${AWS_REGION:?AWS_REGION must be set}"
: "${CLUSTER_NAME:?CLUSTER_NAME must be set}"
: "${TF_STATE_BUCKET:?TF_STATE_BUCKET must be set}"
: "${PROJECT_NAME:?PROJECT_NAME must be set}"
: "${ARGOCD_ADMIN_PASSWORD:?ARGOCD_ADMIN_PASSWORD must be set}"
: "${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD must be set}"
: "${GITOPS_REPO_URL:?GITOPS_REPO_URL must be set}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

ARGOCD_CHART_VERSION="7.7.11"
ALB_CHART_VERSION="1.10.1"

# Kubernetes Secret KEY NAMES (not values) used below.
ARGOCD_HASH_KEY="admin.password"
ARGOCD_MTIME_KEY="admin.passwordMtime"
GRAFANA_KEY="admin-password"

# --- Read infrastructure facts from terraform state ------------------------
# The job reads state itself rather than receiving values through job outputs:
# every one of these embeds the project name, which GitHub masks and silently
# drops from job outputs.
log "Reading terraform outputs"
pushd infra >/dev/null
terraform init -input=false -reconfigure \
  -backend-config="bucket=${TF_STATE_BUCKET}" \
  -backend-config="key=${PROJECT_NAME}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" >/dev/null

VPC_ID="$(terraform output -raw vpc_id)"
ECR_REPO="$(terraform output -raw ecr_repository_url)"
ACM_ARN="$(terraform output -raw acm_certificate_arn)"
ALB_ROLE_ARN="$(terraform output -raw alb_controller_role_arn)"
BASE_DOMAIN="$(terraform output -raw base_domain)"
popd >/dev/null

[ -n "$VPC_ID" ]       || fail "vpc_id output is empty"
[ -n "$ACM_ARN" ]      || fail "acm_certificate_arn is empty — is the cPanel NS delegation live?"
[ -n "$ALB_ROLE_ARN" ] || fail "alb_controller_role_arn output is empty"

log "Cluster=${CLUSTER_NAME} VPC=${VPC_ID} domain=${BASE_DOMAIN}"

# --- Materialise account-specific values into the GitOps tree --------------
# The repo ships placeholders because the repository URL, the ECR registry and
# the certificate ARN are not knowable until the repo and infra exist. The
# workflow commits the result, so what Argo CD reads from git is fully
# resolved — Argo never sees a placeholder.
log "Rendering GitOps manifests for this repository and account"
GITOPS_FILES=(
  gitops/root-app.yaml
  gitops/apps/01-argocd.yaml
  gitops/apps/02-argo-rollouts.yaml
  gitops/apps/03-monitoring.yaml
  gitops/apps/04-shopfast.yaml
  gitops/environments/production/shopfast-values.yaml
)
for f in "${GITOPS_FILES[@]}"; do
  [ -f "$f" ] || fail "expected GitOps file missing: $f"
  sed -i \
    -e "s#PLACEHOLDER_REPO_URL#${GITOPS_REPO_URL}#g" \
    -e "s#PLACEHOLDER_ECR_REPOSITORY#${ECR_REPO}#g" \
    -e "s#PLACEHOLDER_ACM_CERT_ARN#${ACM_ARN}#g" \
    "$f"
done

# The very first bootstrap has no application image yet. Seed the tag with the
# commit being deployed so the chart's "no latest, no empty tag" guard passes;
# the app-release workflow overwrites it on every subsequent release.
if grep -q 'PLACEHOLDER_IMAGE_TAG' gitops/environments/production/shopfast-values.yaml; then
  SEED_TAG="${GITHUB_SHA:-bootstrap}"
  log "Seeding the initial image tag: ${SEED_TAG}"
  sed -i "s#PLACEHOLDER_IMAGE_TAG#${SEED_TAG}#g" \
    gitops/environments/production/shopfast-values.yaml
fi

# --- Namespaces ------------------------------------------------------------
log "Ensuring namespaces"
for ns in argocd argo-rollouts monitoring shopfast; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# --- AWS Load Balancer Controller ------------------------------------------
# Required before any Ingress can produce an ALB, including Argo CD's own.
log "Installing the AWS Load Balancer Controller ${ALB_CHART_VERSION}"
kubectl -n kube-system create serviceaccount aws-load-balancer-controller \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n kube-system annotate serviceaccount aws-load-balancer-controller \
  "eks.amazonaws.com/role-arn=${ALB_ROLE_ARN}" --overwrite

helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --version "${ALB_CHART_VERSION}" \
  --set "clusterName=${CLUSTER_NAME}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set "region=${AWS_REGION}" \
  --set "vpcId=${VPC_ID}" \
  --wait --timeout 10m

# --- Argo CD ---------------------------------------------------------------
log "Installing Argo CD ${ARGOCD_CHART_VERSION}"
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version "${ARGOCD_CHART_VERSION}" \
  --values gitops/platform/argocd/values.yaml \
  --set "global.domain=argocd.${BASE_DOMAIN}" \
  --set "configs.cm.url=https://argocd.${BASE_DOMAIN}" \
  --set "server.ingress.hostname=argocd.${BASE_DOMAIN}" \
  --set-string "server.ingress.annotations.alb\.ingress\.kubernetes\.io/certificate-arn=${ACM_ARN}" \
  --wait --timeout 15m

# --- Argo CD admin credential ----------------------------------------------
# The bcrypt hash is computed here rather than in Terraform, where bcrypt() is
# non-deterministic and would rewrite the hash on every plan. The plaintext is
# read from the environment and never reaches the argument list or a file.
log "Applying the Argo CD admin credential"
ADMIN_HASH="$(printf '%s' "${ARGOCD_ADMIN_PASSWORD}" \
  | htpasswd -niBC 10 "" | tr -d ':\n' | sed 's/^\$2y/\$2a/')"
[ -n "$ADMIN_HASH" ] || fail "failed to compute the Argo CD credential hash"

PATCH_JSON="$(ADMIN_HASH="$ADMIN_HASH" \
  HASH_KEY="$ARGOCD_HASH_KEY" MTIME_KEY="$ARGOCD_MTIME_KEY" \
  MTIME="$(date -u +%FT%TZ)" python3 -c '
import json, os
print(json.dumps({"stringData": {
    os.environ["HASH_KEY"]:  os.environ["ADMIN_HASH"],
    os.environ["MTIME_KEY"]: os.environ["MTIME"],
}}))')"

printf '%s' "$PATCH_JSON" | kubectl -n argocd patch secret argocd-secret --patch-file /dev/stdin
unset ADMIN_HASH PATCH_JSON

kubectl -n argocd rollout restart deployment argocd-server
kubectl -n argocd rollout status deployment argocd-server --timeout=5m

# --- Grafana admin credential ----------------------------------------------
# Piped through a file descriptor so the value is never an argv entry.
log "Creating the Grafana admin credential secret"
GRAFANA_SECRET_YAML="$(GRAFANA_KEY="$GRAFANA_KEY" python3 -c '
import base64, json, os, sys
value = os.environ["GRAFANA_ADMIN_PASSWORD"].encode()
print(json.dumps({
    "apiVersion": "v1", "kind": "Secret", "type": "Opaque",
    "metadata": {"name": "grafana-admin", "namespace": "monitoring"},
    "data": {os.environ["GRAFANA_KEY"]: base64.b64encode(value).decode()},
}))')"
printf '%s' "$GRAFANA_SECRET_YAML" | kubectl apply -f -
unset GRAFANA_SECRET_YAML

# --- Hand over to GitOps ---------------------------------------------------
# The root Application points at gitops/apps/. Everything else — including
# Argo CD's own configuration — is reconciled from git after this point.
log "Applying the App-of-Apps root Application"
kubectl apply -f gitops/root-app.yaml

log "Waiting for Argo CD to register the root application"
for _ in $(seq 1 30); do
  kubectl -n argocd get application root >/dev/null 2>&1 && break
  sleep 5
done
kubectl -n argocd get application root >/dev/null 2>&1 \
  || fail "the root Application was not registered"

log "Bootstrap complete — Argo CD now owns cluster state."
echo "Argo CD:  https://argocd.${BASE_DOMAIN}"
echo "Grafana:  https://grafana.${BASE_DOMAIN}"
echo "ShopFast: https://shopfast.${BASE_DOMAIN}"
