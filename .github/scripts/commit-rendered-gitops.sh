#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Commit the GitOps manifests that the bootstrap resolved.
#
# The repository ships PLACEHOLDER_* tokens for the three values that cannot be
# known before the repo and the infrastructure exist: the repository URL, the
# ECR registry and the ACM certificate ARN. The bootstrap substitutes them; this
# step commits the result so that what Argo CD reads from git is fully resolved.
#
# Runs once in practice — on later deploys there is nothing to commit.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if git diff --quiet -- gitops/; then
  echo "==> GitOps manifests already resolved — nothing to commit."
  exit 0
fi

echo "==> Rendered changes:"
git --no-pager diff --stat -- gitops/

git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add gitops/
git commit -m "chore(gitops): resolve repository, registry and certificate references

Substituted by the bootstrap from terraform outputs so Argo CD reads fully
resolved manifests from git instead of placeholders."

# Rebase in case the app-release workflow pushed a release commit meanwhile.
git pull --rebase origin main
git push origin HEAD:main

echo "==> Resolved GitOps manifests committed."
