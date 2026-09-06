#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Trivy security scans: application filesystem + infrastructure-as-code.
#
# Flags are FEATURE-DETECTED rather than assumed. Trivy's subcommands do not
# share a flag set — `--no-progress` is valid on `fs` and `image` but NOT on
# `config`, which previously failed the whole stage with:
#     FATAL Fatal error unknown flag: --no-progress
# Probing --help costs milliseconds and makes the stage robust across Trivy
# upgrades instead of pinned to one version's exact CLI surface.
#
# Findings are REPORTED, not gated (--exit-code 0), matching the project's
# documented security posture. That threshold is deliberate and unchanged;
# do not relax severities to make a stage pass.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

TRIVY="${TRIVY:-./bin/trivy}"
APP_DIR="${APP_DIR:-application}"
IAC_DIR="${IAC_DIR:-infra}"

[ -x "$TRIVY" ] || { echo "ERROR: trivy not found at $TRIVY" >&2; exit 1; }

# Emit the flag only if this trivy subcommand actually advertises it.
supports() {
  local subcommand="$1" flag="$2"
  "$TRIVY" "$subcommand" --help 2>&1 | grep -q -- "$flag"
}

flag_if_supported() {
  local subcommand="$1" flag="$2"
  if supports "$subcommand" "$flag"; then
    printf '%s' "$flag"
  fi
}

echo "==> Trivy version"
"$TRIVY" --version

# --- Application: dependency vulnerabilities + hardcoded secrets -----------
# --offline-scan stops the Java analyzer resolving unknown POMs from Maven
# Central, which rate-limits the shared GitHub runner IP (HTTP 429,
# Retry-After 1800). Detection still runs from the local vulnerability DB.
echo "==> Trivy filesystem scan: ${APP_DIR}"
# shellcheck disable=SC2046
"$TRIVY" fs \
  --scanners vuln,secret \
  --severity HIGH,CRITICAL \
  --offline-scan \
  --exit-code 0 \
  $(flag_if_supported fs --no-progress) \
  "$APP_DIR"

# --- Infrastructure as code: Terraform misconfiguration --------------------
echo "==> Trivy IaC misconfiguration scan: ${IAC_DIR}"
# shellcheck disable=SC2046
"$TRIVY" config \
  --severity HIGH,CRITICAL \
  --exit-code 0 \
  $(flag_if_supported config --no-progress) \
  "$IAC_DIR"

echo "==> Security scans complete."
