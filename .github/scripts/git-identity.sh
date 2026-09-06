#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Configure the committer identity for CI-authored commits.
#
# MUST be sourced (or run) BEFORE `git commit`, not before `git push`.
# A fresh actions/checkout has no user.name/user.email, so a commit fails with
#
#   Author identity unknown
#   fatal: empty ident name (for <runner@runnervm...>) not allowed
#
# and exit code 128. This lived inside git-push-main.sh, which runs AFTER the
# commit — so the commit died before the push helper was ever reached.
#
# Kept as its own file so both committing scripts share one definition:
#   .github/scripts/commit-rendered-gitops.sh
#   .github/scripts/gitops-bump.sh
# ---------------------------------------------------------------------------
set -Eeuo pipefail

git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
