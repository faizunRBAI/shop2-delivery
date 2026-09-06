#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# THE ONLY PLACE THIS REPOSITORY PUSHES TO ITSELF FROM CI.
#
# Two workflows need to write a commit back to main:
#
#   * app-release / gitops_bump  -> bumps image.tag (this IS the deployment)
#   * deploy / configure         -> commits any manifest the bootstrap resolved
#
# Both used to run a bare `git push origin HEAD:main`, which fails on this
# repository: the rendered workflows declare no `permissions:` block, so the
# job's GITHUB_TOKEN is issued read-only (`Contents: read`) and the push is
# rejected. The pipeline spec has no key for granting workflow permissions,
# so the token cannot be widened from the spec.
#
# The fix is an explicit credential: GITOPS_PAT, a fine-grained Personal
# Access Token with Contents:write on this repository only. It is injected
# into the push URL for the duration of one command and never written to
# .git/config, never echoed, and never persisted in the checkout.
#
# Usage: git-push-main.sh "<what is being pushed, for the log>"
# ---------------------------------------------------------------------------
set -Eeuo pipefail

WHAT="${1:-commit}"

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set — this must run in GitHub Actions}"

if [ -z "${GITOPS_PAT:-}" ]; then
  cat >&2 <<'MSG'
ERROR: GITOPS_PAT is not set.

  This job must push a commit to main, but the workflow's GITHUB_TOKEN is
  read-only and the pipeline spec cannot grant `permissions: contents: write`.

  Create a fine-grained Personal Access Token with
      Repository access: only this repository
      Permissions:       Contents -> Read and write
  and store it as the repository secret GITOPS_PAT.

  Nothing was pushed. Fix the secret and re-run.
MSG
  exit 1
fi

git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

# Rebase first: the other workflow may have pushed while this job ran.
# The token goes on the command line of ONE invocation, never into config.
PUSH_URL="https://x-access-token:${GITOPS_PAT}@github.com/${GITHUB_REPOSITORY}.git"

echo "==> Rebasing onto origin/main before pushing ${WHAT}"
git pull --rebase "$PUSH_URL" main

echo "==> Pushing ${WHAT} to main"
git push "$PUSH_URL" HEAD:main

echo "==> Pushed."
