#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Commit the seed image tag the bootstrap resolved, if any.
#
# SCOPE NOTE: this used to be load-bearing and is deliberately no longer so.
# The repository URL and the ECR registry are now COMMITTED literals, because
# Argo CD reads the child Applications FROM GIT — a placeholder substituted
# only in the runner's working copy is invisible to Argo, which is exactly how
# an earlier deploy failed (every child Application reported
# "failed to get git client for repo PLACEHOLDER_REPO_URL").
#
# What remains is PLACEHOLDER_IMAGE_TAG on a brand-new repository: no image
# exists until the first app-release run, so the bootstrap seeds the tag with
# the deploying commit and this step persists it.
#
# BEST-EFFORT BY DESIGN
# ---------------------
# Unlike gitops-bump.sh, nothing here may fail the platform deploy: Argo CD,
# ingress-nginx, cert-manager and monitoring do not depend on the application
# image at all. Only the `shopfast` Application waits for the first release,
# and verify.sh reports that as a pending action rather than a defect.
#
# That is why the commit and the push are each guarded: `set -e` would
# otherwise abort the whole configure stage on a cosmetic problem, which is
# precisely what happened when the git identity was unset (exit 128).
#
# Credential selection lives in git-push-main.sh (workflow GITHUB_TOKEN by
# default, GITOPS_PAT as an override for orgs that force read-only tokens).
# ---------------------------------------------------------------------------
set -Eeuo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if git diff --quiet -- gitops/; then
  echo "==> GitOps manifests already resolved in git — nothing to commit."
  exit 0
fi

echo "==> Rendered changes:"
git --no-pager diff --stat -- gitops/

if [ -z "${GITOPS_PAT:-}" ] && [ -z "${GITHUB_TOKEN:-}" ]; then
  echo
  echo "::warning title=Seed image tag not committed::No push credential in this job, so the seeded image tag was not persisted. The platform deploy is unaffected; the shopfast Application stays unsynced until the first app-release run."
  echo
  exit 0
fi

# Identity MUST be set before `git commit`, not before `git push`.
bash .github/scripts/git-identity.sh

git add gitops/

if ! git commit -m "chore(gitops): seed the initial image tag

Resolved by the cluster bootstrap so Argo CD reads a concrete image tag from
git instead of a placeholder. Overwritten by every subsequent release."; then
  echo
  echo "::warning title=Seed image tag not committed::git commit failed. The platform deploy is unaffected; run app-release to set a real image tag."
  echo
  exit 0
fi

if ! bash .github/scripts/git-push-main.sh "the seeded image tag"; then
  echo
  echo "::warning title=Seed image tag not pushed::The commit was created locally but could not be pushed. The platform deploy is unaffected; re-run app-release to set a real image tag."
  echo
  exit 0
fi

echo "==> Seed image tag committed."
