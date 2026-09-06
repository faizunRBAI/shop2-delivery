#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Verify that the SHA committed to GitOps actually reached the cluster.
#
# This closes the loop: CI does not claim success because it pushed a commit,
# it waits for Argo CD to sync that revision and for the running pods to report
# the expected image. Read-only against the cluster.
#
# Usage: verify-rollout.sh <git-sha>
# ---------------------------------------------------------------------------
set -Eeuo pipefail

GIT_SHA="${1:?usage: verify-rollout.sh <git-sha>}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-1200}"

echo "==> Waiting for the cluster to converge on ${GIT_SHA}"
DEADLINE=$(( $(date +%s) + TIMEOUT_SECONDS ))

running_image_tags() {
  kubectl -n shopfast get pods \
    -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' 2>/dev/null \
    | awk -F: '{print $NF}' | sort -u
}

while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  SYNC="$(kubectl -n argocd get application shopfast \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo Unknown)"
  HEALTH="$(kubectl -n argocd get application shopfast \
    -o jsonpath='{.status.health.status}' 2>/dev/null || echo Unknown)"
  TAGS="$(running_image_tags | tr '\n' ' ')"

  echo "    sync=${SYNC} health=${HEALTH} running_tags=[${TAGS% }]"

  if [ "$SYNC" = "Synced" ] && [ "$HEALTH" = "Healthy" ] \
     && printf '%s' "$TAGS" | grep -q "$GIT_SHA"; then
    echo "==> Argo CD reports Synced/Healthy and pods are running ${GIT_SHA}"
    break
  fi
  sleep 20
done

# --- Final assertions ------------------------------------------------------
SYNC="$(kubectl -n argocd get application shopfast -o jsonpath='{.status.sync.status}' 2>/dev/null || echo Unknown)"
HEALTH="$(kubectl -n argocd get application shopfast -o jsonpath='{.status.health.status}' 2>/dev/null || echo Unknown)"
TAGS="$(running_image_tags | tr '\n' ' ')"

echo
echo "Final state:"
echo "  Argo CD application : sync=${SYNC} health=${HEALTH}"
echo "  Running image tags  : ${TAGS:-<none>}"
kubectl -n shopfast get rollout,deploy,pods 2>/dev/null || true

if ! printf '%s' "$TAGS" | grep -q "$GIT_SHA"; then
  echo
  echo "ERROR: no running pod is using image tag ${GIT_SHA}." >&2
  echo "Argo CD application conditions:" >&2
  kubectl -n argocd get application shopfast \
    -o jsonpath='{.status.conditions[*].message}{"\n"}' 2>/dev/null >&2 || true
  echo "Rollout status:" >&2
  kubectl -n shopfast describe rollout 2>/dev/null | tail -40 >&2 || true
  exit 1
fi

# A paused canary/blue-green is a legitimate, expected state: the release is
# awaiting promotion, not failing.
ROLLOUT_PHASE="$(kubectl -n shopfast get rollout -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")"
if [ "$ROLLOUT_PHASE" = "Paused" ]; then
  echo
  echo "NOTE: the rollout is PAUSED awaiting promotion — this is the"
  echo "      blue/green or canary gate, not a failure."
  echo "      Promote with:"
  echo "        kubectl argo rollouts -n shopfast promote shopfast"
  exit 0
fi

if [ "$HEALTH" != "Healthy" ] && [ "$ROLLOUT_PHASE" != "Healthy" ]; then
  echo "ERROR: application health is ${HEALTH} (rollout phase ${ROLLOUT_PHASE:-unknown})" >&2
  exit 1
fi

echo
echo "==> Release ${GIT_SHA} is live and healthy."
