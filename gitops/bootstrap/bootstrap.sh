#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Cluster bootstrap — the ONLY imperative step in the whole platform.
#
# It installs the components that cannot install themselves (ingress-nginx,
# cert-manager and Argo CD), seeds their credentials, materialises the
# account-specific values into the GitOps tree, and hands ownership of
# everything else to the App-of-Apps root Application. From that point on the
# cluster's desired state is whatever is committed under gitops/.
#
# WHY ingress-nginx AND cert-manager ARE INSTALLED HERE TOO
# ---------------------------------------------------------
# They are also declared as Argo Applications (waves -2 and -1) so Argo owns
# them going forward. But Argo CD's OWN ingress needs an IngressClass and a
# certificate to be reachable at all, and Argo cannot create the controller
# that serves its own dashboard before it is running. Installing them here with
# the SAME chart versions and the SAME values files makes the subsequent Argo
# sync a no-op adoption rather than a conflicting second install.
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

# Chart versions — MUST match the targetRevision in gitops/apps/*.yaml, or the
# Argo sync will immediately "upgrade" what this script just installed.
ARGOCD_CHART_VERSION="7.7.11"
NGINX_CHART_VERSION="4.11.3"
CERT_MANAGER_CHART_VERSION="v1.16.2"

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
BASE_DOMAIN="$(terraform output -raw base_domain)"
popd >/dev/null

[ -n "$VPC_ID" ]     || fail "vpc_id output is empty"
[ -n "$ECR_REPO" ]   || fail "ecr_repository_url output is empty"
[ -n "$BASE_DOMAIN" ] || fail "base_domain output is empty"

log "Cluster=${CLUSTER_NAME} VPC=${VPC_ID} domain=${BASE_DOMAIN}"

# --- Materialise account-specific values into the GitOps tree --------------
# The repo ships placeholders because the repository URL and the ECR registry
# are not knowable until the repo and infra exist. The workflow commits the
# result, so what Argo CD reads from git is fully resolved — Argo never sees a
# placeholder.
#
# There is no certificate ARN to substitute: TLS is issued in-cluster by
# cert-manager.
log "Rendering GitOps manifests for this repository and account"
GITOPS_FILES=(
  gitops/root-app.yaml
  gitops/apps/00-ingress-nginx.yaml
  gitops/apps/00b-cert-manager.yaml
  gitops/apps/00c-cert-manager-issuer.yaml
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
for ns in argocd argo-rollouts monitoring shopfast ingress-nginx cert-manager; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

# --- Helm repositories -----------------------------------------------------
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null 2>&1 || true
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null

# --- ingress-nginx ---------------------------------------------------------
# Must exist before any Ingress (including Argo CD's own) can be served, and
# before cert-manager can solve an HTTP-01 challenge.
log "Installing ingress-nginx ${NGINX_CHART_VERSION}"
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --version "${NGINX_CHART_VERSION}" \
  --values gitops/platform/ingress-nginx/values.yaml \
  --wait --timeout 10m

# The NLB is created asynchronously by the AWS cloud provider after the Service
# exists. Everything downstream (DNS, ACME challenges, the verify stage) is
# blocked until it has a hostname, so wait for it explicitly rather than
# letting a later step fail with a confusing error.
log "Waiting for the AWS load balancer to be assigned to the ingress Service"
NLB_HOSTNAME=""
for _ in $(seq 1 60); do
  NLB_HOSTNAME="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [ -n "$NLB_HOSTNAME" ] && break
  sleep 10
done
[ -n "$NLB_HOSTNAME" ] || fail "the ingress-nginx Service never received a load balancer hostname (check the AWS cloud provider and the kubernetes.io/role/elb subnet tags)"

log "Public load balancer: ${NLB_HOSTNAME}"

# Surface the CNAME targets prominently — this is the operator's manual step.
{
  echo "::notice title=cPanel DNS records required::Create these CNAME records in cPanel, all pointing at ${NLB_HOSTNAME}"
  echo "::notice title=CNAME 1::argocd.shop2 -> ${NLB_HOSTNAME}"
  echo "::notice title=CNAME 2::grafana.shop2 -> ${NLB_HOSTNAME}"
  echo "::notice title=CNAME 3::shopfast.shop2 -> ${NLB_HOSTNAME}"
} || true

# --- cert-manager ----------------------------------------------------------
log "Installing cert-manager ${CERT_MANAGER_CHART_VERSION}"
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version "${CERT_MANAGER_CHART_VERSION}" \
  --values gitops/platform/cert-manager/values.yaml \
  --wait --timeout 10m

# The ClusterIssuers are CRD instances; apply them only once the CRDs are
# established, or the apply fails with "no matches for kind ClusterIssuer".
log "Waiting for the cert-manager CRDs to be established"
kubectl wait --for=condition=Established crd/clusterissuers.cert-manager.io --timeout=180s
kubectl wait --for=condition=Available deployment/cert-manager-webhook \
  -n cert-manager --timeout=300s

log "Applying the ACME ClusterIssuers"
# The webhook can briefly reject admission right after becoming Available;
# retry rather than failing the whole bootstrap on a startup race.
for attempt in $(seq 1 10); do
  if kubectl apply -f gitops/platform/cert-manager-issuer/cluster-issuer.yaml; then
    break
  fi
  [ "$attempt" -eq 10 ] && fail "could not apply the ClusterIssuers"
  log "ClusterIssuer apply rejected (webhook still starting), retrying in 15s"
  sleep 15
done

# --- Argo CD ---------------------------------------------------------------
log "Installing Argo CD ${ARGOCD_CHART_VERSION}"
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version "${ARGOCD_CHART_VERSION}" \
  --values gitops/platform/argocd/values.yaml \
  --set "global.domain=argocd.${BASE_DOMAIN}" \
  --set "configs.cm.url=https://argocd.${BASE_DOMAIN}" \
  --set "server.ingress.hostname=argocd.${BASE_DOMAIN}" \
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
# Argo CD's own configuration, ingress-nginx and cert-manager — is reconciled
# from git after this point.
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
echo
echo "  Public load balancer: ${NLB_HOSTNAME}"
echo
echo "  Point these cPanel CNAME records at it:"
echo "    argocd.shop2   -> ${NLB_HOSTNAME}"
echo "    grafana.shop2  -> ${NLB_HOSTNAME}"
echo "    shopfast.shop2 -> ${NLB_HOSTNAME}"
echo
echo "  Once DNS resolves, cert-manager issues certificates automatically:"
echo "    https://argocd.${BASE_DOMAIN}"
echo "    https://grafana.${BASE_DOMAIN}"
echo "    https://shopfast.${BASE_DOMAIN}"
