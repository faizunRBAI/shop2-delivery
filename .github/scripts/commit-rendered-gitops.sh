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
# The push needs the GITOPS_PAT credential (the workflow GITHUB_TOKEN is
# read-only and the pipeline spec cannot grant contents: write). If that
# secret is absent, the PLATFORM deploy must still succeed — Argo CD, nginx,
# cert-manager and monitoring do not depend on the app image at all. Only the
# `shopfast` Application stays unsynced until the first real release, and
# verify.sh reports that as a pending action rather than a defect.
#
# So: a missing PAT produces a loud warning here, never a failed deploy.
# The app-release pipeline treats the same missing secret as FATAL, because
# there a failed push means a release that silently never happened.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if git diff --quiet -- gitops/; then
  echo "==> GitOps manifests already resolved in git — nothing to commit."
  exit 0
fi

echo "==> Rendered changes:"
git --no-pager diff --stat -- gitops/

if [ -z "${GITOPS_PAT:-}" ]; then
  cat <<'MSG'

::warning title=Seed image tag not committed::GITOPS_PAT is not set, so the seeded image tag could not be pushed. The platform deploy is unaffected; the shopfast Application will stay unsynced until the first app-release run.

  To enable it, create a fine-grained Personal Access Token with
      Repository access: only this repository
      Permissions:       Contents -> Read and write
  and store it as the repository secret GITOPS_PAT.

MSG
  exit 0
fi

git add gitops/
git commit -m "chore(gitops): seed the initial image tag

Resolved by the cluster bootstrap so Argo CD reads a concrete image tag from
git instead of a placeholder. Overwritten by every subsequent release."

bash .github/scripts/git-push-main.sh "the seeded image tag"

echo "==> Seed image tag committed."
