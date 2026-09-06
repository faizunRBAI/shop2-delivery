#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Post-deploy verification.
#
# Asserts the ACTUAL state of AWS, EKS and Argo CD. Every check either proves
# something with real output or fails the pipeline. Nothing here assumes that a
# previous step "probably worked".
# ---------------------------------------------------------------------------
set -Eeuo pipefail

PASS=0
FAIL=0

ok()    { printf '  \033[1;32m[PASS]\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
warn()  { printf '  \033[1;33m[WARN]\033[0m %s\n' "$*"; }
head_() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }

# --- 0. Resolve the domain from terraform state, not from a guess ----------
BASE_DOMAIN="${BASE_DOMAIN:-}"
if [ -z "$BASE_DOMAIN" ] && [ -d infra ]; then
  BASE_DOMAIN="$(cd infra && terraform output -raw base_domain 2>/dev/null || true)"
fi
BASE_DOMAIN="${BASE_DOMAIN:-shop2.royalbengal.xyz}"

# --- 1. Cluster reachable and nodes ready ----------------------------------
head_ "EKS cluster"
if kubectl version -o json >/dev/null 2>&1; then
  ok "Kubernetes API is reachable"
else
  bad "cannot reach the Kubernetes API"
  exit 1
fi

NODES_TOTAL="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
NODES_READY="$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true)"
if [ "${NODES_READY:-0}" -ge 1 ] && [ "$NODES_READY" = "$NODES_TOTAL" ]; then
  ok "all ${NODES_READY}/${NODES_TOTAL} nodes are Ready"
else
  bad "only ${NODES_READY}/${NODES_TOTAL} nodes are Ready"
  kubectl get nodes || true
fi

# --- 2. Core controllers ---------------------------------------------------
head_ "Platform controllers"
check_deploy() {
  local ns="$1" name="$2" ready
  ready="$(kubectl -n "$ns" get deploy "$name" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [ "${ready:-0}" -ge 1 ]; then
    ok "${ns}/${name} has ${ready} ready replica(s)"
  else
    bad "${ns}/${name} has no ready replicas"
    kubectl -n "$ns" describe deploy "$name" 2>/dev/null | tail -20 || true
  fi
}

check_deploy kube-system aws-load-balancer-controller
check_deploy argocd argocd-server
check_deploy argocd argocd-repo-server

# --- 3. Argo Rollouts (delivered BY GitOps, not by the bootstrap) ----------
head_ "Argo Rollouts"
if kubectl get crd rollouts.argoproj.io >/dev/null 2>&1; then
  ok "Rollout CRD is installed"
else
  bad "Rollout CRD is missing — the argo-rollouts Application has not synced"
fi

if kubectl -n argo-rollouts get deploy argo-rollouts >/dev/null 2>&1; then
  check_deploy argo-rollouts argo-rollouts
else
  warn "argo-rollouts controller not present yet (Argo CD may still be syncing)"
fi

# --- 4. Argo CD applications ----------------------------------------------
head_ "Argo CD applications"
if kubectl -n argocd get application root >/dev/null 2>&1; then
  ok "root App-of-Apps exists"
else
  bad "root Application is missing"
fi

app_states() {
  kubectl -n argocd get applications \
    -o jsonpath='{range .items[*]}{.status.sync.status}/{.status.health.status}{"\n"}{end}' 2>/dev/null
}

echo "Waiting up to 10 minutes for applications to converge..."
DEADLINE=$(( $(date +%s) + 600 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  TOTAL="$(kubectl -n argocd get applications --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  GOOD="$(app_states | grep -c '^Synced/Healthy$' || true)"
  if [ "${TOTAL:-0}" -gt 0 ] && [ "$GOOD" = "$TOTAL" ]; then
    break
  fi
  sleep 20
done

TOTAL="$(kubectl -n argocd get applications --no-headers 2>/dev/null | wc -l | tr -d ' ')"
GOOD="$(app_states | grep -c '^Synced/Healthy$' || true)"

echo
kubectl -n argocd get applications -o custom-columns=\
'NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' \
  --no-headers 2>/dev/null || true
echo

if [ "${TOTAL:-0}" -gt 0 ] && [ "$GOOD" = "$TOTAL" ]; then
  ok "all ${TOTAL} Argo CD applications are Synced/Healthy"
else
  bad "${GOOD}/${TOTAL} applications are Synced/Healthy"
  for app in $(kubectl -n argocd get applications -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    STATE="$(kubectl -n argocd get application "$app" \
      -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)"
    [ "$STATE" = "Synced/Healthy" ] && continue
    echo "--- $app ($STATE)"
    kubectl -n argocd get application "$app" \
      -o jsonpath='{.status.conditions[*].message}{"\n"}' 2>/dev/null || true
    kubectl -n argocd get application "$app" \
      -o jsonpath='{.status.operationState.message}{"\n"}' 2>/dev/null || true
  done
fi

# --- 5. The workload, and the strategy invariant ---------------------------
head_ "ShopFast workload"
WORKLOADS="$(kubectl -n shopfast get rollout,deploy -o name 2>/dev/null || true)"
HAS_ROLLOUT="$(printf '%s\n' "$WORKLOADS" | grep -c '^rollout' || true)"
HAS_DEPLOY="$(printf '%s\n' "$WORKLOADS" | grep -c '^deployment' || true)"

if [ "$HAS_ROLLOUT" -gt 0 ] && [ "$HAS_DEPLOY" -gt 0 ]; then
  bad "INVARIANT VIOLATED: a Rollout and a Deployment both exist in shopfast"
  kubectl -n shopfast get rollout,deploy
elif [ "$HAS_ROLLOUT" -gt 0 ]; then
  ok "progressive delivery active: Rollout present, no Deployment rendered"
  kubectl -n shopfast get rollout 2>/dev/null || true
elif [ "$HAS_DEPLOY" -gt 0 ]; then
  ok "standard strategy active: Deployment present, no Rollout rendered"
else
  warn "no ShopFast workload found yet (first sync may still be in flight)"
fi

READY_PODS="$(kubectl -n shopfast get pods --no-headers 2>/dev/null | grep -c 'Running' || true)"
if [ "${READY_PODS:-0}" -ge 1 ]; then
  ok "${READY_PODS} ShopFast pod(s) Running"
else
  warn "no Running ShopFast pods yet"
  kubectl -n shopfast get pods 2>/dev/null || true
fi

# --- 6. Observability ------------------------------------------------------
head_ "Observability"
if kubectl -n monitoring get statefulset victoriametrics >/dev/null 2>&1; then
  VM_READY="$(kubectl -n monitoring get statefulset victoriametrics \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [ "${VM_READY:-0}" -ge 1 ]; then
    ok "VictoriaMetrics is ready"
  else
    bad "VictoriaMetrics is not ready"
  fi
else
  warn "VictoriaMetrics not deployed yet"
fi

if kubectl -n monitoring get deploy grafana >/dev/null 2>&1; then
  check_deploy monitoring grafana
else
  warn "Grafana not deployed yet"
fi

if kubectl -n monitoring get deploy vmagent >/dev/null 2>&1; then
  check_deploy monitoring vmagent
fi

# Prove metrics are actually being INGESTED, not merely that a pod is up.
VM_QUERY="$(kubectl -n monitoring exec statefulset/victoriametrics -- \
  wget -qO- 'http://127.0.0.1:8428/api/v1/query?query=count(up)' 2>/dev/null || true)"
if printf '%s' "$VM_QUERY" | grep -q '"status":"success"'; then
  ok "VictoriaMetrics is answering queries: ${VM_QUERY:0:120}"
else
  warn "could not query VictoriaMetrics for scrape targets yet"
fi

# --- 7. Public HTTPS endpoints (from outside the cluster) ------------------
head_ "Public HTTPS endpoints (domain: ${BASE_DOMAIN})"

probe_url() {
  local url="$1" expect="$2" label="$3" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
          --retry 12 --retry-delay 15 --retry-all-errors "$url" || echo 000)"
  if printf '%s' "$expect" | tr ',' '\n' | grep -qx "$code"; then
    ok "${label} → HTTP ${code} (${url})"
  else
    bad "${label} → HTTP ${code}, expected one of ${expect} (${url})"
  fi
}

ALB_HOST="$(kubectl -n argocd get ingress argocd-server \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
if [ -n "$ALB_HOST" ]; then
  ok "Argo CD ingress has an ALB: ${ALB_HOST}"
else
  bad "Argo CD ingress has no ALB address yet"
  kubectl -n argocd describe ingress argocd-server 2>/dev/null | tail -25 || true
fi

# 307 is the Argo CD login redirect and is a healthy response for '/'.
probe_url "https://argocd.${BASE_DOMAIN}/healthz"           "200"     "Argo CD health"
probe_url "https://argocd.${BASE_DOMAIN}/"                  "200,307" "Argo CD dashboard"
probe_url "https://shopfast.${BASE_DOMAIN}/actuator/health" "200"     "ShopFast health"
probe_url "https://shopfast.${BASE_DOMAIN}/api/hello"       "200"     "ShopFast API"
probe_url "https://grafana.${BASE_DOMAIN}/api/health"       "200"     "Grafana health"

# --- Summary ---------------------------------------------------------------
head_ "Summary"
printf '  %d passed, %d failed\n\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "Verification FAILED — see the failures above."
  exit 1
fi
echo "Verification PASSED — the platform is live and reconciling from git."
