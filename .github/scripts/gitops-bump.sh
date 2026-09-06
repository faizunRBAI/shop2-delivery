#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# THE DEPLOYMENT.
#
# Rewrites image.tag in the production values file to the git SHA that was just
# pushed to ECR, and commits it. That commit IS the release: Argo CD notices the
# new desired state and Argo Rollouts performs the blue/green or canary
# progression. Nothing in this script talks to the cluster.
#
# The push is delegated to git-push-main.sh, which owns credential selection
# (the workflow GITHUB_TOKEN by default, GITOPS_PAT as an override).
#
# A FAILED PUSH IS FATAL HERE, deliberately: this script's commit is the only
# thing that makes a release happen, so a push that silently did not land would
# leave CI green while production still runs the previous image.
#
# Usage: gitops-bump.sh <git-sha>
# ---------------------------------------------------------------------------
set -Eeuo pipefail

GIT_SHA="${1:?usage: gitops-bump.sh <git-sha>}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

VALUES_FILE="gitops/environments/production/shopfast-values.yaml"
[ -f "$VALUES_FILE" ] || { echo "ERROR: ${VALUES_FILE} not found" >&2; exit 1; }

CURRENT_TAG="$(grep -E '^[[:space:]]+tag:' "$VALUES_FILE" | head -1 | sed -E 's/.*tag:[[:space:]]*"?([^"]*)"?.*/\1/')"
echo "==> Current image tag: ${CURRENT_TAG:-<none>}"
echo "==> New image tag:     ${GIT_SHA}"

if [ "$CURRENT_TAG" = "$GIT_SHA" ]; then
  echo "==> Already at ${GIT_SHA} — nothing to commit."
  exit 0
fi

# Replace only the tag line inside the image: block.
python3 - "$VALUES_FILE" "$GIT_SHA" <<'PY'
import re, sys

path, new_tag = sys.argv[1], sys.argv[2]
with open(path) as fh:
    lines = fh.readlines()

in_image, changed = False, False
for i, line in enumerate(lines):
    if re.match(r'^image:\s*$', line):
        in_image = True
        continue
    # A new top-level key ends the image block.
    if in_image and re.match(r'^\S', line):
        in_image = False
    if in_image and re.match(r'^\s+tag:', line):
        indent = re.match(r'^(\s+)', line).group(1)
        lines[i] = f'{indent}tag: "{new_tag}"\n'
        changed = True
        break

if not changed:
    sys.exit("ERROR: could not find image.tag in " + path)

with open(path, 'w') as fh:
    fh.writelines(lines)
print(f"Updated image.tag -> {new_tag}")
PY

echo "==> Diff:"
git --no-pager diff -- "$VALUES_FILE"

git add "$VALUES_FILE"
git commit -m "deploy(shopfast): roll production to ${GIT_SHA}

Image: immutable ECR tag ${GIT_SHA}.
Argo CD reconciles this commit and Argo Rollouts performs the progressive
rollout. No cluster mutation happens in CI."

bash .github/scripts/git-push-main.sh "the release commit for ${GIT_SHA}"

echo "==> Release committed. Argo CD owns the rest."
