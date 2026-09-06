#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Install the Trivy scanner into ./bin.
#
# Uses the vendor's official install script, which resolves the correct release
# asset for the runner's OS/architecture itself.
#
# TRIVY_VERSION is verified to exist upstream (checked against the GitHub
# release list, not assumed). A previous revision of this pipeline pinned
# v0.58.1 — a version that was never released — and every scan stage died with
# `curl: (22) ... 404`. If you bump this, verify the tag first:
#     gh release list --repo aquasecurity/trivy
#
# Why not a hand-built release URL: it hardcodes both a version AND an exact
# asset filename convention, so it has two independent ways to rot.
# Why not aquasecurity/trivy-action: this platform's fix-memory records
# repeated breakage from upstream tag deletions and nested-action pins.
#
# Single call site: BOTH the deploy `security` stage and the app-release
# `image_scan` stage source the scanner from here, so the two cannot drift.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

TRIVY_VERSION="${TRIVY_VERSION:-v0.74.0}"
INSTALL_DIR="${INSTALL_DIR:-./bin}"

mkdir -p "$INSTALL_DIR"

echo "==> Installing Trivy ${TRIVY_VERSION} into ${INSTALL_DIR}"
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
  | sh -s -- -b "$INSTALL_DIR" "$TRIVY_VERSION"

# Prove the binary is actually runnable before any stage depends on it.
"${INSTALL_DIR}/trivy" --version
echo "==> Trivy is ready."
