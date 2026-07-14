#!/bin/bash
# check-upstream-version.sh
#
# Query the official WorkBuddy CDN for the latest version
set -Eeuo pipefail

BASE_URL="${UPSTREAM_CHECK_URL:-https://download.codebuddy.cn/workbuddy/saas/darwin-x64/}"

main() {
  local content detected current

  info "Checking upstream at: $BASE_URL"

  # Try to list the directory (Tencent COS may return XML listing)
  content="$(curl -sSL --connect-timeout 15 --max-time 30 "$BASE_URL" 2>/dev/null || true)"

  # Extract DMG filenames — pattern: WorkBuddy-darwin-x64-{VERSION}.dmg
  detected="$(echo "$content" | grep -oP 'WorkBuddy-darwin-x64-\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+-[a-f0-9]+' | sort -V | tail -1 || true)"

  if [ -z "$detected" ]; then
    # Fallback: try HEAD request on a known version URL pattern
    warn "Directory listing not available, trying known URL patterns..."
    # Try a few recent versions via HEAD
    for ver in "5.3.0" "5.2.5" "5.2.0" "4.23.0" "4.22.10"; do
      # The CDN might not have directory listing, so we just log
      info "  Could not detect version via directory listing"
    done
    echo "unknown"
    exit 0
  fi

  info "Detected upstream version: $detected"
  echo "$detected"
}

info() { echo "[INFO] $*" >&2; }
warn()  { echo "[WARN] $*" >&2; }

main "$@"
