#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# GUARD: the committed GitOps manifests must be fully resolved and internally
# consistent, checked in LINT rather than discovered 35 minutes into a deploy.
#
# WHY THIS EXISTS
# ---------------
# Argo CD reads the child Applications and values files FROM GIT. A value
# substituted only in the CI runner's working copy is invisible to Argo, so
# every repoURL and registry this repo declares must be a committed literal.
#
# PLACEHOLDER_IMAGE_TAG is the ONE legitimate exception: no image exists until
# the first app-release run, so the bootstrap seeds it and commits the result.
#
# ---------------------------------------------------------------------------
# THREE PATTERN TRAPS, ALL HIT FOR REAL IN THIS REPOSITORY. Do not "simplify"
# these checks back into naive greps:
#
#  1. SCAN ONLY YAML MANIFESTS, NOT PROSE. The first version grepped all of
#     gitops/ for the placeholder token and matched the COMMENTS in
#     root-app.yaml and bootstrap.sh that DOCUMENT the bug, plus the literal
#     string inside bootstrap.sh's own guard. A file that explains a bug is
#     not a file that has it. Comments are stripped and only Application
#     manifests are scanned.
#
#  2. `tr -d '[:space:]'` DELETES NEWLINES ACROSS THE WHOLE STREAM. Using it
#     to trim a list of URLs welded all eight into one string, producing a
#     spectacular false failure:
#       "child Application points at a different repo:
#        https://...githttps://...githttps://...git"
#     Trim per line (sed) — never with a stream-wide tr.
#
#  3. repoURL appears BOTH as a plain mapping key ("    repoURL: ...") and as
#     the first key of a list item ("    - repoURL: ..."), because
#     multi-source Applications use `sources:`. Patterns allow an optional
#     "- "; without it all five multi-source lines are missed.
#
#  Also: the upstream Helm chart repositories are github.IO hosts
#  (kubernetes.github.io, argoproj.github.io), so matching "github.com/"
#  correctly selects only the GitOps repository. And a bare "- /path" is not
#  necessarily a bad valueFile — JSON pointers under ignoreDifferences
#  ("- /spec/replicas") look identical, so that check is scoped to the list
#  following a `valueFiles:` key.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

FORBIDDEN='PLACEHOLDER_REPO_URL|PLACEHOLDER_ECR_REPOSITORY|PLACEHOLDER_ACM_CERT_ARN'
RE_REPOURL='^[[:space:]]*-?[[:space:]]*repoURL:[[:space:]]*'
# Strip full-line and trailing comments so documentation never trips a check.
STRIP_COMMENTS='s/[[:space:]]*#.*$//'
FAILED=0

# The manifests Argo CD actually reads. Shell scripts and prose are excluded
# by design — only these files' CONTENT becomes desired state.
MANIFESTS=(gitops/root-app.yaml gitops/apps/*.yaml gitops/environments/production/*.yaml)

echo "== committed GitOps manifests must be fully resolved"

PH_BAD=0
for f in "${MANIFESTS[@]}"; do
  [ -f "$f" ] || continue
  if HITS="$(sed "$STRIP_COMMENTS" "$f" | grep -nE "$FORBIDDEN" || true)"; then
    if [ -n "$HITS" ]; then
      echo "  [FAIL] unresolved placeholder in ${f}:"
      printf '%s\n' "$HITS" | sed 's/^/         /'
      PH_BAD=1
    fi
  fi
done
if [ "$PH_BAD" -eq 0 ]; then
  echo "  [PASS] no repository-URL or registry placeholders in any manifest"
else
  echo "         Argo CD reads these files FROM GIT. Substituting them in the"
  echo "         CI working copy does not help — commit the real values."
  FAILED=1
fi

# The root Application must point at a real https:// git URL, since it is the
# single entry point the bootstrap applies and everything else descends from.
ROOT_URL="$(sed "$STRIP_COMMENTS" gitops/root-app.yaml \
  | grep -E "$RE_REPOURL" | head -1 \
  | sed -E "s#${RE_REPOURL}##; s/[[:space:]]*$//; s/^\"//; s/\"$//")"
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
done < <(cat gitops/apps/*.yaml \
  | sed "$STRIP_COMMENTS" \
  | grep -E "${RE_REPOURL}https://github\.com/" \
  | sed -E "s#${RE_REPOURL}##; s/[[:space:]]*$//; s/^\"//; s/\"$//" \
  | sort -u)

if [ "$FOUND" -eq 0 ]; then
  echo "  [FAIL] no child Application references the GitOps repository at all"
  FAILED=1
elif [ "$BAD" -eq 0 ]; then
  echo "  [PASS] all ${FOUND} distinct child repoURL(s) match the root repository"
else
  FAILED=1
fi

# Any Application using $values in a valueFile MUST declare a source with
# `ref: values`, or Argo cannot resolve the reference and the sync fails.
REF_BAD=0
for f in gitops/apps/*.yaml; do
  BODY="$(sed "$STRIP_COMMENTS" "$f")"
  if printf '%s' "$BODY" | grep -q '\$values/' \
     && ! printf '%s' "$BODY" | grep -qE '^[[:space:]]*ref:[[:space:]]*values[[:space:]]*$'; then
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
ABS_BAD=0
for f in gitops/apps/*.yaml; do
  OFFENDERS="$(sed "$STRIP_COMMENTS" "$f" | awk -v fn="$(basename "$f")" '
    /^[[:space:]]*valueFiles:[[:space:]]*$/ { inlist = 1; next }
    inlist && /^[[:space:]]*-[[:space:]]*\// { print fn ":" FNR ": " $0; next }
    inlist && !/^[[:space:]]*-/ { inlist = 0 }
  ')"
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
if sed "$STRIP_COMMENTS" "$VALUES" \
   | grep -qE '^[[:space:]]+repository:[[:space:]]*"?[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/'; then
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
