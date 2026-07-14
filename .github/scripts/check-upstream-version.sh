#!/bin/bash
# check-upstream-version.sh
#
# Query the official WorkBuddy download site for the latest version.
# This script is used by the GitHub Actions scheduled workflow to detect
# new upstream releases. Set UPSTREAM_CHECK_URL to point at a page or
# API endpoint that contains the version string.
#
# The script prints the detected version to stdout so the workflow can
# capture it and compare against the package.json version.
set -Eeuo pipefail

# ── Configurable ────────────────────────────────────────────────────────────
# Official WorkBuddy download page — the maintainer should set this via
# GitHub Actions variable or edit it here.
UPSTREAM_CHECK_URL="${UPSTREAM_CHECK_URL:-https://workbuddy.tencent.com/download}"

# Regex that extracts a SemVer-like version from the fetched content.
# Adjust this if the upstream site uses a different version format.
VERSION_PATTERN="${VERSION_PATTERN:-([0-9]+\.[0-9]+\.[0-9]+)}"

# ── Helpers ─────────────────────────────────────────────────────────────────
info()  { echo "[INFO] $*" >&2; }
warn()  { echo "[WARN] $*" >&2; }
error() { echo "[ERROR] $*" && exit 1; }

# ── Main ────────────────────────────────────────────────────────────────────
main() {
  local content detected current

  info "Checking upstream at: $UPSTREAM_CHECK_URL"

  # Fetch the upstream page (try common download page patterns)
  content="$(curl -sSL --connect-timeout 15 --max-time 30 "$UPSTREAM_CHECK_URL" 2>/dev/null || true)"

  if [ -z "$content" ]; then
    # Fallback: try the Tencent WorkBuddy API if the download page is unreachable
    warn "Download page unreachable, trying alternate methods..."
    # Attempt to find version via known patterns in the product page
    content="$(curl -sSL --connect-timeout 15 --max-time 30 "https://workbuddy.tencent.com" 2>/dev/null || true)"
  fi

  if [ -z "$content" ]; then
    error "Upstream site unreachable — cannot check version."
  fi

  # Try to extract a version number from the page
  detected="$(echo "$content" | grep -oP "$VERSION_PATTERN" | head -1 || true)"

  if [ -z "$detected" ]; then
    warn "Could not extract version with pattern '$VERSION_PATTERN'."
    warn "The upstream site may have changed its layout."
    warn "Set VERSION_PATTERN in the GitHub Actions variable or edit this script."
    exit 0  # Non-fatal — we just skip the automated check
  fi

  info "Detected upstream version: $detected"

  # Compare against the current package.json version
  current="$(node -e "console.log(require('$REPO_DIR/package.json').version)" 2>/dev/null || echo "0.0.0")"
  info "Current local version: $current"

  if [ "$detected" != "$current" ]; then
    info "New version available: $detected (current: $current)"
    echo "NEW_VERSION=$detected" >> "$GITHUB_OUTPUT" 2>/dev/null || true
  else
    info "Upstream version unchanged."
  fi

  echo "$detected"
}

main "$@"
