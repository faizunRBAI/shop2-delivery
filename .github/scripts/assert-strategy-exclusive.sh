#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Enforce the chart's central invariant in CI:
#
#   "Never render a normal Deployment when Blue/Green or Canary is enabled."
#
# This renders the chart in all three modes and asserts the exact workload kind
# produced. A regression in the template guards fails the build here, before it
# can reach a cluster.
#
# It also asserts the TRAFFIC ROUTING contract. Canary weights are applied by
# the Argo Rollouts NGINX traffic router against a stable Ingress; if that
# wiring is lost the rollout still "succeeds" while sending 100% of traffic to
# the stable version, which is a silent and very expensive failure.
#
# NOTE ON MATCHING: helm preserves YAML comments in rendered output, so every
# assertion below runs against a COMMENT-STRIPPED copy. Matching raw text made
# an earlier version of this script fail on a template comment that merely
# DOCUMENTED an annotation. Assert on what Kubernetes would actually receive.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

CHART="application/helm/shopfast"
COMMON=(
  --set image.repository=example.dkr.ecr.us-east-1.amazonaws.com/shopfast
  --set image.tag=assertsha
)

FAIL=0
pass() { printf '  \033[1;32m[PASS]\033[0m %s\n' "$*"; }
bad()  { printf '  \033[1;31m[FAIL]\033[0m %s\n' "$*"; FAIL=1; }

# Render, then drop full-line comments and trailing comments so assertions see
# only effective YAML. (Values in this chart never contain a '#'.)
render() {
  helm template shopfast "$CHART" --set "deploymentStrategy=$1" "${COMMON[@]}" \
    | sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d'
}

count_kind() {
  # Count documents whose kind is exactly $2 in the rendered output $1.
  printf '%s\n' "$1" | grep -cE "^kind:[[:space:]]+$2[[:space:]]*$" || true
}

echo "== deploymentStrategy=standard"
OUT="$(render standard)"
D="$(count_kind "$OUT" Deployment)"
R="$(count_kind "$OUT" Rollout)"
[ "$D" -eq 1 ] && pass "renders exactly 1 Deployment" || bad "expected 1 Deployment, got $D"
[ "$R" -eq 0 ] && pass "renders no Rollout"           || bad "expected 0 Rollouts, got $R"

echo "== deploymentStrategy=bluegreen"
OUT="$(render bluegreen)"
D="$(count_kind "$OUT" Deployment)"
R="$(count_kind "$OUT" Rollout)"
[ "$R" -eq 1 ] && pass "renders exactly 1 Rollout"    || bad "expected 1 Rollout, got $R"
[ "$D" -eq 0 ] && pass "renders NO Deployment"        || bad "INVARIANT BROKEN: $D Deployment(s) rendered with bluegreen"
printf '%s' "$OUT" | grep -q 'blueGreen:' \
  && pass "uses the blueGreen strategy" || bad "blueGreen strategy block missing"
printf '%s' "$OUT" | grep -q 'shopfast-preview' \
  && pass "creates the preview service" || bad "preview service missing"

echo "== deploymentStrategy=canary"
OUT="$(render canary)"
D="$(count_kind "$OUT" Deployment)"
R="$(count_kind "$OUT" Rollout)"
[ "$R" -eq 1 ] && pass "renders exactly 1 Rollout"    || bad "expected 1 Rollout, got $R"
[ "$D" -eq 0 ] && pass "renders NO Deployment"        || bad "INVARIANT BROKEN: $D Deployment(s) rendered with canary"
printf '%s' "$OUT" | grep -q 'canary:' \
  && pass "uses the canary strategy"    || bad "canary strategy block missing"
printf '%s' "$OUT" | grep -q 'setWeight' \
  && pass "defines traffic weight steps" || bad "canary steps missing"

echo "== canary traffic routing (nginx)"
# Without a trafficRouting block Argo Rollouts silently degrades to replica-
# count-based canarying: the steps still run, but no traffic is actually
# split. Assert the nginx router and its stable ingress reference explicitly.
printf '%s' "$OUT" | grep -q 'trafficRouting:' \
  && pass "declares trafficRouting" || bad "trafficRouting block missing — weights would be ignored"
printf '%s' "$OUT" | grep -qE '^[[:space:]]+nginx:[[:space:]]*$' \
  && pass "uses the nginx traffic router" || bad "nginx traffic router missing"
printf '%s' "$OUT" | grep -q 'stableIngress:' \
  && pass "references a stable ingress" || bad "stableIngress missing — the router cannot find the ingress to copy"

# The stable ingress named by the router must actually be rendered by the chart.
STABLE_ING="$(printf '%s' "$OUT" | grep 'stableIngress:' | head -1 | awk '{print $2}')"
if [ -n "$STABLE_ING" ] && printf '%s' "$OUT" | grep -qE "^  name: ${STABLE_ING}$"; then
  pass "stable ingress '${STABLE_ING}' is rendered by the chart"
else
  bad "stableIngress '${STABLE_ING:-?}' does not match any rendered resource name"
fi

# The Rollouts controller creates the canary ingress itself. If the chart also
# rendered one, the two would fight over the same object forever.
#
# Assert on ANNOTATION KEYS in effective YAML: a canary annotation is a mapping
# key, so it is followed by a colon at the start of a (whitespace-indented)
# line. A bare mention anywhere else is not a rendered annotation.
CANARY_ANNOTATIONS="$(printf '%s\n' "$OUT" \
  | grep -cE '^[[:space:]]+nginx\.ingress\.kubernetes\.io/canary(-weight)?:' || true)"
if [ "$CANARY_ANNOTATIONS" -eq 0 ]; then
  pass "chart does not render a canary ingress (owned by the controller)"
else
  bad "chart renders ${CANARY_ANNOTATIONS} canary annotation(s) — it would fight the Rollouts controller"
  printf '%s\n' "$OUT" | grep -nE '^[[:space:]]+nginx\.ingress\.kubernetes\.io/canary(-weight)?:' || true
fi

# Belt and braces: exactly one Ingress in canary mode (the stable one).
ING_COUNT="$(count_kind "$OUT" Ingress)"
[ "$ING_COUNT" -eq 1 ] \
  && pass "renders exactly 1 Ingress in canary mode" \
  || bad "expected exactly 1 Ingress in canary mode, got ${ING_COUNT}"

echo "== ingress TLS contract"
printf '%s' "$OUT" | grep -q 'cert-manager.io/cluster-issuer' \
  && pass "ingress requests a cert-manager certificate" || bad "cert-manager cluster-issuer annotation missing"
printf '%s' "$OUT" | grep -qE '^[[:space:]]+ingressClassName: nginx$' \
  && pass "ingress targets the nginx IngressClass" || bad "ingressClassName is not nginx"
# ALB annotations would mean the AWS Load Balancer Controller is expected — it
# is not installed in this cluster, so the ingress would never be served.
if printf '%s\n' "$OUT" | grep -qE '^[[:space:]]+alb\.ingress\.kubernetes\.io/'; then
  bad "ALB annotations still present — the AWS LB Controller is not installed"
  printf '%s\n' "$OUT" | grep -nE '^[[:space:]]+alb\.ingress\.kubernetes\.io/' || true
else
  pass "no stale ALB annotations remain"
fi

echo "== immutable tag guard"
if helm template shopfast "$CHART" \
     --set deploymentStrategy=canary \
     --set image.repository=example.dkr.ecr.us-east-1.amazonaws.com/shopfast \
     --set image.tag=latest >/dev/null 2>&1; then
  bad "chart accepted image.tag=latest — the guard is not working"
else
  pass "chart rejects image.tag=latest"
fi

echo "== invalid strategy guard"
if helm template shopfast "$CHART" \
     --set deploymentStrategy=nonsense \
     --set image.repository=example.dkr.ecr.us-east-1.amazonaws.com/shopfast \
     --set image.tag=assertsha >/dev/null 2>&1; then
  bad "chart accepted an unknown deploymentStrategy"
else
  pass "chart rejects an unknown deploymentStrategy"
fi

echo
if [ "$FAIL" -ne 0 ]; then
  echo "Strategy invariant assertions FAILED."
  exit 1
fi
echo "All strategy invariant assertions passed."
