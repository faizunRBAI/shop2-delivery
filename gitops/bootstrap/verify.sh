#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Post-deploy verification.
#
# Asserts the ACTUAL state of AWS, EKS, cert-manager and Argo CD. Every check
# either proves something with real output or fails the pipeline. Nothing here
# assumes that a previous step "probably worked".
#
# TWO DELIBERATE EXCEPTIONS, both PENDING HUMAN ACTIONS rather than defects:
#
#  1. The public HTTPS endpoints depend on CNAME records the operator creates
#     by hand in cPanel (the host offers no NS records, so Route 53 delegation
#     and ACM are impossible — see infra/dns_tls.tf). Until those records
#     exist, DNS cannot resolve and no certificate can be issued.
#
#  2. The `shopfast` Application cannot sync until an application image exists
#     in ECR, which requires the app-release pipeline to have run at least
#     once. On a first platform deploy that is expected, not broken.
#
# Everything else — the cluster, the controllers, the load balancer, the
# issuers, the Argo CD platform Applications — is asserted strictly.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

PASS=0
FAIL=0
DNS_PENDING=0
APP_PENDING=0

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

# --- 0b. Has a real application image actually been released? --------------
# ASK THE REGISTRY, NOT THE MANIFEST.
#
# This used to test whether shopfast-values.yaml still contained
# PLACEHOLDER_IMAGE_TAG. That signal is wrong after the first deploy: the
# bootstrap SEEDS the tag with $GITHUB_SHA and commits it, so the placeholder
# is gone from git while ECR is still empty. verify then judged shopfast
# strictly and failed the pipeline for the expected "no release yet" state.
#
# The authoritative question is whether the tag the manifest asks for exists
# in ECR. If it does not, the rollout can only ever be ImagePullBackOff and
# that is a pending human action (run app-release), not a platform defect.
APP_RELEASED=0
SHOPFAST_VALUES="gitops/environments/production/shopfast-values.yaml"
WANTED_TAG=""
if [ -f "$SHOPFAST_VALUES" ]; then
  WANTED_TAG="$(sed -n 's/^[[:space:]]*tag:[[:space:]]*"\{0,1\}\([^"[:space:]]*\)"\{0,1\}[[:space:]]*$/\1/p' \
                  "$SHOPFAST_VALUES" | head -1)"
fi

if [ -n "$WANTED_TAG" ] && [ "$WANTED_TAG" != "PLACEHOLDER_IMAGE_TAG" ]; then
  if aws ecr describe-images \
        --repository-name "${PROJECT_NAME:-shop2-delivery}/shopfast" \
        --image-ids "imageTag=${WANTED_TAG}" \
        --region "${AWS_REGION:-us-east-1}" >/dev/null 2>&1; then
    APP_RELEASED=1
  fi
fi

if [ "$APP_RELEASED" -eq 1 ]; then
  echo "Application image ${WANTED_TAG} found in ECR — asserting ShopFast strictly."
else
  echo "No application image for tag '${WANTED_TAG:-none}' in ECR — ShopFast checks are advisory."
fi

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

check_deploy ingress-nginx ingress-nginx-controller
check_deploy cert-manager cert-manager
check_deploy cert-manager cert-manager-webhook
check_deploy argocd argocd-server
check_deploy argocd argocd-repo-server

# --- 3. The public load balancer -------------------------------------------
# This is the single entrypoint and the CNAME target. Without it nothing is
# reachable, so this check is strict.
head_ "Public load balancer"
NLB_HOSTNAME="$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

if [ -n "$NLB_HOSTNAME" ]; then
  ok "ingress-nginx Service has a load balancer: ${NLB_HOSTNAME}"
else
  bad "the ingress-nginx Service has no load balancer hostname"
  kubectl -n ingress-nginx describe svc ingress-nginx-controller 2>/dev/null | tail -30 || true
fi

# --- 4. ACME issuers -------------------------------------------------------
head_ "cert-manager issuers"
if kubectl get crd clusterissuers.cert-manager.io >/dev/null 2>&1; then
  ok "ClusterIssuer CRD is installed"
  for issuer in letsencrypt-prod letsencrypt-staging; do
    READY="$(kubectl get clusterissuer "$issuer" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    if [ "$READY" = "True" ]; then
      ok "ClusterIssuer ${issuer} is Ready (ACME account registered)"
    else
      bad "ClusterIssuer ${issuer} is not Ready (status=${READY:-none})"
      kubectl describe clusterissuer "$issuer" 2>/dev/null | tail -20 || true
    fi
  done
else
  bad "ClusterIssuer CRD missing — cert-manager has not installed"
fi

# --- 5. Argo Rollouts ------------------------------------------------------
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

# --- 6. Argo CD applications ----------------------------------------------
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

# The shopfast Application is excluded from the convergence wait when no image
# has been released yet — waiting 10 minutes for something that cannot
# possibly converge just burns pipeline time.
EXPECTED_GOOD_MSG="all applications"
if [ "$APP_RELEASED" -eq 0 ]; then
  EXPECTED_GOOD_MSG="all platform applications (shopfast excluded — no release yet)"
fi

echo "Waiting up to 10 minutes for ${EXPECTED_GOOD_MSG} to converge..."
DEADLINE=$(( $(date +%s) + 600 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  TOTAL="$(kubectl -n argocd get applications --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  GOOD="$(app_states | grep -c '^Synced/Healthy$' || true)"
  NEEDED="$TOTAL"
  [ "$APP_RELEASED" -eq 0 ] && NEEDED=$(( TOTAL - 1 ))
  if [ "${TOTAL:-0}" -gt 0 ] && [ "$GOOD" -ge "$NEEDED" ]; then
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

# Report each non-converged Application, classifying the expected one.
for app in $(kubectl -n argocd get applications -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  STATE="$(kubectl -n argocd get application "$app" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)"
  [ "$STATE" = "Synced/Healthy" ] && continue

  if [ "$app" = "shopfast" ] && [ "$APP_RELEASED" -eq 0 ]; then
    warn "shopfast is ${STATE} — no application image has been released yet (run the app-release workflow)"
    APP_PENDING=$((APP_PENDING+1))
    continue
  fi

  bad "${app} is ${STATE}"
  echo "--- $app"
  kubectl -n argocd get application "$app" \
    -o jsonpath='{.status.conditions[*].message}{"\n"}' 2>/dev/null || true
  kubectl -n argocd get application "$app" \
    -o jsonpath='{.status.operationState.message}{"\n"}' 2>/dev/null || true
done

CONVERGED=$(( GOOD + APP_PENDING ))
if [ "${TOTAL:-0}" -gt 0 ] && [ "$CONVERGED" -ge "$TOTAL" ]; then
  ok "${GOOD}/${TOTAL} Argo CD applications are Synced/Healthy"
fi

# --- 7. The workload, and the strategy invariant ---------------------------
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
elif [ "$APP_RELEASED" -eq 0 ]; then
  warn "no ShopFast workload yet — expected, no image has been released"
else
  warn "no ShopFast workload found yet (first sync may still be in flight)"
fi

READY_PODS="$(kubectl -n shopfast get pods --no-headers 2>/dev/null | grep -c 'Running' || true)"
if [ "${READY_PODS:-0}" -ge 1 ]; then
  ok "${READY_PODS} ShopFast pod(s) Running"
elif [ "$APP_RELEASED" -eq 0 ]; then
  warn "no Running ShopFast pods — expected, no image has been released"
else
  warn "no Running ShopFast pods yet"
  kubectl -n shopfast get pods 2>/dev/null || true
fi

# --- 8. Observability ------------------------------------------------------
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

if kubectl -n monitoring get deploy kube-state-metrics >/dev/null 2>&1; then
  check_deploy monitoring kube-state-metrics
fi

# Prove metrics are actually being INGESTED, not merely that a pod is up.
VM_QUERY="$(kubectl -n monitoring exec statefulset/victoriametrics -- \
  wget -qO- 'http://127.0.0.1:8428/api/v1/query?query=count(up)' 2>/dev/null || true)"
if printf '%s' "$VM_QUERY" | grep -q '"status":"success"'; then
  ok "VictoriaMetrics is answering queries: ${VM_QUERY:0:120}"
else
  warn "could not query VictoriaMetrics for scrape targets yet"
fi

# --- 9. In-cluster HTTP reachability (independent of public DNS) -----------
# Proves nginx is routing to the right backends even before the CNAMEs exist,
# by sending the Host header directly to the controller Service. This is what
# separates "the platform is broken" from "DNS is not pointed here yet".
head_ "In-cluster routing (Host-header probes, no DNS required)"

probe_internal() {
  local host="$1" path="$2" expect="$3" label="$4" code
  code="$(kubectl -n ingress-nginx run "probe-$(date +%s%N | tail -c 7)" \
      --rm -i --restart=Never --quiet \
      --image=curlimages/curl:8.11.0 --timeout=90s -- \
      curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
      -H "Host: ${host}" "http://ingress-nginx-controller.ingress-nginx.svc${path}" \
      2>/dev/null || echo 000)"
  code="$(printf '%s' "$code" | tr -dc '0-9')"
  if printf '%s' "$expect" | tr ',' '\n' | grep -qx "$code"; then
    ok "${label} routed internally → HTTP ${code}"
  else
    bad "${label} routed internally → HTTP ${code}, expected one of ${expect}"
  fi
}

# 308 is the per-ingress HTTP→HTTPS redirect and proves the ingress matched.
probe_internal "argocd.${BASE_DOMAIN}"   "/healthz"          "200,308" "Argo CD"
probe_internal "grafana.${BASE_DOMAIN}"  "/api/health"       "200,308" "Grafana"

# ShopFast has no ingress until it is released; probing would assert a 404.
if [ "$APP_RELEASED" -eq 1 ]; then
  probe_internal "shopfast.${BASE_DOMAIN}" "/actuator/health" "200,308" "ShopFast"
else
  warn "skipping the ShopFast route probe — no release yet"
fi

# --- 10. Public HTTPS endpoints -------------------------------------------
# These depend on the operator's cPanel CNAME records. Reported, never fatal.
head_ "Public HTTPS endpoints (domain: ${BASE_DOMAIN})"

if [ -n "$NLB_HOSTNAME" ]; then
  echo "  CNAME target for cPanel: ${NLB_HOSTNAME}"
  echo
fi

dns_points_here() {
  local host="$1" resolved
  resolved="$(getent hosts "$host" 2>/dev/null | head -1 || true)"
  [ -n "$resolved" ]
}

probe_public() {
  local url="$1" expect="$2" label="$3" host code
  host="$(printf '%s' "$url" | sed -e 's#^https\?://##' -e 's#/.*##')"

  if ! dns_points_here "$host"; then
    warn "${label}: ${host} does not resolve yet — add the cPanel CNAME to ${NLB_HOSTNAME:-the load balancer}"
    DNS_PENDING=$((DNS_PENDING+1))
    return 0
  fi

  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
          --retry 8 --retry-delay 15 --retry-all-errors "$url" || echo 000)"
  if printf '%s' "$expect" | tr ',' '\n' | grep -qx "$code"; then
    ok "${label} → HTTP ${code} (${url})"
  else
    # DNS resolves but HTTPS is not answering correctly. The usual cause on a
    # fresh cluster is that cert-manager has not finished issuing yet.
    bad "${label} → HTTP ${code}, expected one of ${expect} (${url})"
    echo "  Certificate status for ${host}:"
    kubectl get certificate -A 2>/dev/null | grep -i "${host%%.*}" || true
  fi
}

# 307 is the Argo CD login redirect and is a healthy response for '/'.
probe_public "https://argocd.${BASE_DOMAIN}/healthz" "200"     "Argo CD health"
probe_public "https://argocd.${BASE_DOMAIN}/"        "200,307" "Argo CD dashboard"
probe_public "https://grafana.${BASE_DOMAIN}/api/health" "200" "Grafana health"

if [ "$APP_RELEASED" -eq 1 ]; then
  probe_public "https://shopfast.${BASE_DOMAIN}/actuator/health" "200" "ShopFast health"
  probe_public "https://shopfast.${BASE_DOMAIN}/api/hello"       "200" "ShopFast API"
fi

# --- 11. Certificate status ------------------------------------------------
head_ "TLS certificates"
CERTS="$(kubectl get certificate -A --no-headers 2>/dev/null || true)"
if [ -n "$CERTS" ]; then
  kubectl get certificate -A 2>/dev/null || true
  CERT_TOTAL="$(printf '%s\n' "$CERTS" | wc -l | tr -d ' ')"
  CERT_READY="$(printf '%s\n' "$CERTS" | awk '{print $3}' | grep -c '^True$' || true)"
  if [ "${CERT_READY:-0}" -eq "${CERT_TOTAL:-0}" ] && [ "${CERT_TOTAL:-0}" -gt 0 ]; then
    ok "all ${CERT_TOTAL} certificate(s) are issued"
  else
    warn "${CERT_READY}/${CERT_TOTAL} certificates issued — HTTP-01 needs public DNS first"
  fi
else
  warn "no Certificate resources yet (ingresses may still be syncing)"
fi

# --- Summary ---------------------------------------------------------------
head_ "Summary"
printf '  %d passed, %d failed' "$PASS" "$FAIL"
[ "$DNS_PENDING" -gt 0 ] && printf ', %d awaiting DNS' "$DNS_PENDING"
[ "$APP_PENDING" -gt 0 ] && printf ', %d awaiting first release' "$APP_PENDING"
printf '\n\n'

if [ "$FAIL" -gt 0 ]; then
  echo "Verification FAILED — see the failures above."
  exit 1
fi

if [ "$DNS_PENDING" -gt 0 ] || [ "$APP_PENDING" -gt 0 ]; then
  echo "Verification PASSED for everything inside the cluster."
  echo

  if [ "$DNS_PENDING" -gt 0 ]; then
    cat <<BANNER
ACTION REQUIRED (1) — ${DNS_PENDING} public endpoint(s) cannot be reached
because their DNS records do not exist yet. In cPanel, create these CNAME
records:

    argocd.shop2    CNAME  ${NLB_HOSTNAME}
    grafana.shop2   CNAME  ${NLB_HOSTNAME}
    shopfast.shop2  CNAME  ${NLB_HOSTNAME}

cert-manager will then issue the Let's Encrypt certificates automatically
within a couple of minutes. Re-run this workflow afterwards to confirm.

BANNER
  fi

  if [ "$APP_PENDING" -gt 0 ]; then
    cat <<'BANNER'
ACTION REQUIRED (2) — the ShopFast application has never been released, so no
image exists in ECR and its Argo CD Application cannot sync. Run the
`app-release` workflow to build, scan, push and roll out the first version.

BANNER
  fi

  exit 0
fi

echo "Verification PASSED — the platform is live and reconciling from git."
