#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Enforce the chart's central invariant in CI:
#
#   "Never render a normal Deployment when Blue/Green or Canary is enabled."
#
# This renders the chart in all three modes and asserts the exact workload kind
# produced. A regression in the template guards fails the build here, before it
# can reach a cluster.
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

render() {
  helm template shopfast "$CHART" --set "deploymentStrategy=$1" "${COMMON[@]}"
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
