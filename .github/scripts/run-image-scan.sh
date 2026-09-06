#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Trivy container image scan for the app-release pipeline.
#
# Same feature-detection discipline as run-security-scan.sh: Trivy subcommands
# do not share a flag set, so optional flags are probed via --help rather than
# assumed. See that script's header for the failure this prevents.
#
# Usage: run-image-scan.sh <image-ref>
# ---------------------------------------------------------------------------
set -Eeuo pipefail

IMAGE_REF="${1:?usage: run-image-scan.sh <image-ref>}"
TRIVY="${TRIVY:-./bin/trivy}"

[ -x "$TRIVY" ] || { echo "ERROR: trivy not found at $TRIVY" >&2; exit 1; }

flag_if_supported() {
  local subcommand="$1" flag="$2"
  if "$TRIVY" "$subcommand" --help 2>&1 | grep -q -- "$flag"; then
    printf '%s' "$flag"
  fi
}

echo "==> Trivy version"
"$TRIVY" --version

# --offline-scan: the image carries a Spring Boot fat jar, so without it the
# Java analyzer resolves POMs from Maven Central and hits the shared-runner
# rate limit (HTTP 429).
echo "==> Trivy image scan: ${IMAGE_REF}"
# shellcheck disable=SC2046
"$TRIVY" image \
  --severity HIGH,CRITICAL \
  --offline-scan \
  --exit-code 0 \
  $(flag_if_supported image --no-progress) \
  "$IMAGE_REF"

echo "==> Image scan complete."
