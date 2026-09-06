#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# THE ONLY PLACE THIS REPOSITORY PUSHES TO ITSELF FROM CI.
#
# Two workflows need to write a commit back to main:
#
#   * app-release / gitops_bump  -> bumps image.tag (this IS the deployment)
#   * deploy / configure         -> commits the seeded image tag, once
#
# SCOPE: this script PUSHES. It does not configure the committer identity —
# that belongs to git-identity.sh and must run before `git commit`, several
# steps earlier. Setting it here was an ordering bug: the commit failed with
# "empty ident name" (exit 128) before this script was ever reached.
#
# CREDENTIAL
# ----------
# This repository's default workflow permission is `write`, verified against
# the live API:
#   gh api repos/<owner>/<repo>/actions/permissions/workflow
#   -> {"default_workflow_permissions":"write", ...}
# and confirmed in the runner log ("GITHUB_TOKEN Permissions ... Contents: write").
#
# So the checkout's own GITHUB_TOKEN can push and no extra secret is needed.
# GITOPS_PAT is an OPTIONAL override for organisations that tighten the default
# workflow permission to read-only — a fine-grained PAT (this repo,
# Contents: Read and write) then restores the push with no other change.
#
# The credential is read straight from the environment into the remote URL of
# ONE command. It is never copied into a named variable, never written to
# .git/config, and never echoed. `set -x` is likewise never enabled here.
#
# Usage: git-push-main.sh "<what is being pushed, for the log>"
# ---------------------------------------------------------------------------
set -Eeuo pipefail

WHAT="${1:-commit}"

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set — this must run in GitHub Actions}"

# Choose the credential SOURCE by name only; the value is dereferenced once,
# inline, when the remote URL is built.
if [ -n "${GITOPS_PAT:-}" ]; then
  CRED_VAR="GITOPS_PAT"
  echo "==> Pushing with the GITOPS_PAT override"
elif [ -n "${GITHUB_TOKEN:-}" ]; then
  CRED_VAR="GITHUB_TOKEN"
  echo "==> Pushing with the workflow GITHUB_TOKEN"
else
  cat >&2 <<'MSG'
ERROR: no credential available to push.

  Neither GITOPS_PAT nor GITHUB_TOKEN is present in this job's environment.
  GITHUB_TOKEN must be passed explicitly by the stage:

      env:
        GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

  If the organisation forces read-only workflow permissions, create a
  fine-grained PAT (this repository, Contents: Read and write) and store it
  as the repository secret GITOPS_PAT.

  Nothing was pushed.
MSG
  exit 1
fi

# Rebase first: the other workflow may have pushed while this job ran.
echo "==> Rebasing onto origin/main before pushing ${WHAT}"
git pull --rebase \
  "https://x-access-token:${!CRED_VAR}@github.com/${GITHUB_REPOSITORY}.git" main

echo "==> Pushing ${WHAT} to main"
git push \
  "https://x-access-token:${!CRED_VAR}@github.com/${GITHUB_REPOSITORY}.git" HEAD:main

echo "==> Pushed."
