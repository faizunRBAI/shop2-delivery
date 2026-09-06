#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUARD: the committed GitOps manifests must be fully resolved and internally
# consistent, checked in LINT rather than discovered 35 minutes into a deploy.
#
# WHY THIS EXISTS
# ---------------
# Argo CD reads the child Applications and values files FROM GIT. A value
# substituted only in the CI runner's working copy is invisible to Argo.
#
# An earlier version of this platform substituted PLACEHOLDER_REPO_URL during
# the configure stage and relied on a follow-up commit to persist it. That
# commit silently never landed (the workflow GITHUB_TOKEN is read-only), so
# Argo CD read the placeholder from git and every child Application failed:
#
#   ComparisonError: Failed to load target state: failed to generate manifest
#   for source 1 of 2: rpc error: code = Unknown desc = failed to get git
#   client for repo PLACEHOLDER_REPO_URL
#
# PLACEHOLDER_IMAGE_TAG is the ONE legitimate exception: no image exists until
# the first app-release run, so the bootstrap seeds it.
#
# PATTERN FACTS — ALL VERIFIED AGAINST THE REAL FILES WITH `git grep`, never
# assumed. A previous assertion in this repo shipped a regex that matched a
# YAML comment and failed an otherwise-green build; these were checked first:
#
#   1. repoURL appears BOTH as a plain mapping key ("    repoURL: ...") and
#      as the first key of a list item ("    - repoURL: ..."), because
#      multi-source Applications use `sources:`. Patterns allow an optional
#      "- ". Without it, all five multi-source lines are missed.
#   2. The upstream Helm chart repositories are github.IO hosts
#      (kubernetes.github.io, argoproj.github.io). Matching "github.com/"
#      selects only the GitOps repository and correctly skips those.
#   3. A bare "- /path" list item is NOT necessarily a bad valueFile: JSON
#      pointers in ignoreDifferences ("- /spec/replicas", "- /data/...") look
#      identical. The absolute-path check is therefore scoped to the lines
#      that actually follow a `valueFiles:` key.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FORBIDDEN='PLACEHOLDER_REPO_URL|PLACEHOLDER_ECR_REPOSITORY|PLACEHOLDER_ACM_CERT_ARN'
RE_REPOURL='^[[:space:]]*-?[[:space:]]*repoURL:[[:space:]]*'
FAILED=0

echo "== committed GitOps manifests must be fully resolved"

if MATCHES="$(grep -RInE "$FORBIDDEN" gitops/ 2>/dev/null)"; then
  echo "  [FAIL] unresolved placeholders are committed under gitops/:"
  printf '%s\n' "$MATCHES" | sed 's/^/         /'
  echo
  echo "         Argo CD reads these files FROM GIT. Substituting them in the"
  echo "         CI working copy does not help — commit the real values."
  FAILED=1
else
  echo "  [PASS] no repository-URL or registry placeholders committed"
fi

# The root Application must point at a real https:// git URL, since it is the
# single entry point the bootstrap applies and everything else descends from.
ROOT_URL="$(grep -E "$RE_REPOURL" gitops/root-app.yaml | head -1 \
  | sed -E "s#${RE_REPOURL}##" | tr -d '"' | tr -d '[:space:]')"
if [[ "$ROOT_URL" =~ ^https://github\.com/.+\.git$ ]]; then
  echo "  [PASS] root-app repoURL is a concrete git URL: ${ROOT_URL}"
else
  echo "  [FAIL] root-app repoURL is not a concrete GitHub git URL: '${ROOT_URL}'"
  FAILED=1
fi

# Every child Application that references the GitOps repo must reference the
# SAME repository as the root, or the App-of-Apps silently spans two repos.
BAD=0
FOUND=0
while IFS= read -r u; do
  [ -z "$u" ] && continue
  FOUND=$((FOUND + 1))
  if [ "$u" != "$ROOT_URL" ]; then
    echo "  [FAIL] child Application points at a different repo: ${u}"
    BAD=1
  fi
done < <(grep -rhE "${RE_REPOURL}https://github\.com/" gitops/apps/ \
  | sed -E "s#${RE_REPOURL}##" | tr -d '"' | tr -d '[:space:]' | sort -u)

if [ "$FOUND" -eq 0 ]; then
  echo "  [FAIL] no child Application references the GitOps repository at all"
  FAILED=1
elif [ "$BAD" -eq 0 ]; then
  echo "  [PASS] all ${FOUND} distinct child repoURL(s) target the root repository"
else
  FAILED=1
fi

# Any Application using $values in a valueFile MUST declare a source with
# `ref: values`, or Argo cannot resolve the reference and the sync fails.
REF_BAD=0
for f in gitops/apps/*.yaml; do
  if grep -q '\$values/' "$f" && ! grep -qE '^[[:space:]]*ref:[[:space:]]*values[[:space:]]*$' "$f"; then
    echo "  [FAIL] $(basename "$f") uses \$values but declares no 'ref: values' source"
    REF_BAD=1
  fi
done
if [ "$REF_BAD" -eq 0 ]; then
  echo "  [PASS] every \$values reference has a matching ref source"
else
  FAILED=1
fi

# A helm valueFile outside the chart directory must go through $values — Argo
# resolves valueFiles relative to the CHART path and refuses to escape it, so
# an absolute-looking path silently fails to load.
#
# SCOPED to the list that follows a `valueFiles:` key. A naive repo-wide grep
# for "- /..." also matches the JSON pointers under ignoreDifferences
# (/spec/replicas, /data/admin.password) and reports three false failures —
# verified against the real files before writing this.
ABS_BAD=0
for f in gitops/apps/*.yaml; do
  OFFENDERS="$(awk '
    /^[[:space:]]*valueFiles:[[:space:]]*$/ { inlist = 1; next }
    inlist && /^[[:space:]]*-[[:space:]]*\// { print FILENAME ":" FNR ": " $0; next }
    inlist && !/^[[:space:]]*-/ { inlist = 0 }
  ' "$f")"
  if [ -n "$OFFENDERS" ]; then
    echo "  [FAIL] absolute valueFile path (use \$values/<path> instead):"
    printf '%s\n' "$OFFENDERS" | sed 's/^/         /'
    ABS_BAD=1
  fi
done
if [ "$ABS_BAD" -eq 0 ]; then
  echo "  [PASS] no absolute valueFile paths"
else
  FAILED=1
fi

# The production values file must carry a real ECR registry host.
VALUES="gitops/environments/production/shopfast-values.yaml"
if grep -qE '^[[:space:]]+repository:[[:space:]]*"?[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/' "$VALUES"; then
  echo "  [PASS] production values reference a concrete ECR registry"
else
  echo "  [FAIL] ${VALUES} has no concrete ECR registry in image.repository"
  FAILED=1
fi

echo
if [ "$FAILED" -ne 0 ]; then
  echo "GitOps resolution assertions FAILED."
  exit 1
fi
echo "GitOps resolution assertions passed."
