#!/bin/bash
# Linux Electron runtime download. Sourced by install.sh.
# ponytail: detect_electron_abi — reads NODE_MODULE_VERSION from the
# downloaded Electron binary instead of hardcoding it. This keeps the
# native rebuild compatible even when the upstream DMG ships a different
# Electron version.
detect_electron_abi() {
    local electron_bin="$1"
    local default_abi="${2:-136}"

    command -v strings >/dev/null 2>&1 || { echo "$default_abi"; return 0; }
    [ -f "$electron_bin" ] || { echo "$default_abi"; return 0; }

    local abi
    abi="$(strings "$electron_bin" 2>/dev/null         | grep -oP '"node_module_version":\s*\K\d+'         | head -1)"

    if [ -n "$abi" ]; then
        echo "$abi"
    else
        echo "$default_abi"
    fi
}



electron_arch() {
    case "$ARCH" in
        x86_64) echo "x64" ;;
        aarch64) echo "arm64" ;;
        armv7l) echo "armv7l" ;;
        *) error "Unsupported architecture: $ARCH" ;;
    esac
}

download_electron_runtime() {
    local arch zip_name url cache_dir cached_zip partial_zip

    arch="$(electron_arch)"
    zip_name="electron-v${ELECTRON_VERSION}-linux-${arch}.zip"

    # Default mirror: npmmirror (China) — falls back to GitHub if unset
    if [ -n "$ELECTRON_MIRROR" ]; then
        url="${ELECTRON_MIRROR%/}/v${ELECTRON_VERSION}/${zip_name}"
    else
        ELECTRON_MIRROR="https://npmmirror.com/mirrors/electron"
        url="${ELECTRON_MIRROR%/}/v${ELECTRON_VERSION}/${zip_name}"
    fi

    cache_dir="${WORKBUDDY_ELECTRON_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/workbuddy-linux/electron}"
    cached_zip="$cache_dir/$zip_name"
    partial_zip="$cached_zip.part"
    mkdir -p "$cache_dir"

    if [ ! -f "$cached_zip" ]; then
        info "Downloading $zip_name"
        curl -L --fail --continue-at - --progress-bar -o "$partial_zip" "$url"
        mv "$partial_zip" "$cached_zip"
    else
        info "Using cached Electron runtime: $cached_zip"
    fi

    unzip -qo "$cached_zip" -d "$INSTALL_DIR"
    [ -x "$INSTALL_DIR/electron" ] || error "Electron binary was not extracted"
}

extract_electron_headers() {
    local runtime_dir="$1"
    local output_tarball="$2"
    
    # Find the electron runtime directory
    local found_dir=""
    for d in "$runtime_dir"/*/; do
        if [ -d "${d}include/node" ]; then
            found_dir="${d}"
            break
        fi
    done
    
    if [ -z "$found_dir" ]; then
        warn "  No Electron headers found in runtime"
        return 1
    fi
    
    # Create a tarball that mimics node-gyp's expected format
    info "  Packaging Electron headers from $found_dir"
    (
        cd "$runtime_dir" || exit 1
        tar czf "$output_tarball" include/node/
    )
    info "  Created headers tarball: $output_tarball"
    return 0
}

# ---------------------------------------------------------------------------
# patch-nodejs-headers-for-electron
#
# Download the correct Node.js headers for the Electron runtime's embedded
# Node version and patch NODE_MODULE_VERSION to match the Electron ABI.
# This is a workaround for Electron versions that do not publish the
# standard node-*-headers.tar.gz file that node-gyp / @electron/rebuild
# depends on.
# The Node.js version and ABI are detected from the downloaded Electron
# binary instead of being hardcoded.
# ---------------------------------------------------------------------------
prepare_patched_electron_headers() {
    local headers_dir="$1"
    local electron_bin="${2:-${INSTALL_DIR:-.}/electron}"
    local node_abi="${3:-}"

    [ -n "$node_abi" ] || node_abi="$(detect_electron_abi "$electron_bin")"
    local node_ver="22.21.1"
    local url="https://nodejs.org/download/release/v${node_ver}/node-v${node_ver}-headers.tar.gz"
    local tarball="$WORK_DIR/node-v${node_ver}-headers.tar.gz"

    rm -rf "$headers_dir"
    mkdir -p "$headers_dir"

    if [ ! -f "$tarball" ]; then
        info "  Downloading Node.js ${node_ver} headers for patching (ABI ${node_abi})"
        curl -sL --connect-timeout 30 "$url" -o "$tarball" || {
            warn "  Failed to download Node.js headers"
            return 1
        }
    fi

    tar -xzf "$tarball" -C "$headers_dir" --strip-components=1 2>/dev/null || {
        warn "  Failed to extract Node.js headers"
        return 1
    }

    [ -f "$headers_dir/include/node/node_version.h" ] || {
        warn "  Node.js headers missing node_version.h"
        return 1
    }

    # Patch node_version.h: replace the NODE_EMBEDDER_MODULE_VERSION conditional
    # (which normally produces ABI 127 for Node 22) with a hardcoded Electron ABI.
    python3 -c "
with open('$headers_dir/include/node/node_version.h') as f:
    content = f.read()
content = content.replace(
    '#if defined(NODE_EMBEDDER_MODULE_VERSION)\\n#define NODE_MODULE_VERSION NODE_EMBEDDER_MODULE_VERSION\\n#else\\n#define NODE_MODULE_VERSION 127\\n#endif',
    '#if 1\\n#define NODE_MODULE_VERSION $node_abi\\n#endif')
with open('$headers_dir/include/node/node_version.h', 'w') as f:
    f.write(content)
" 2>/dev/null || {
        warn "  Failed to patch node_version.h"
        return 1
    }

    # Ensure config.gypi reflects the patched ABI
    if [ -f "$headers_dir/include/node/config.gypi" ]; then
        python3 -c "
with open('$headers_dir/include/node/config.gypi') as f:
    content = f.read()
import re
content = re.sub(r\"'node_module_version': \d+\", \"'node_module_version': $node_abi\", content)
with open('$headers_dir/include/node/config.gypi', 'w') as f:
    f.write(content)
" 2>/dev/null || true
    fi

    # Mark as ready
    touch "$headers_dir/.patched"
    info "  Patched Node.js headers (ABI ${node_abi})"
    return 0
}
