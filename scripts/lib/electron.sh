#!/bin/bash
# Linux Electron runtime download. Sourced by install.sh.

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
    local headers_dir="$2"
    
    if [ -d "$runtime_dir/include/node" ]; then
        mkdir -p "$headers_dir"
        cp -a "$runtime_dir/include/node/"* "$headers_dir/"
        info "  Extracted Electron headers from runtime"
        return 0
    fi
    
    warn "  No headers found in electron runtime"
    return 1
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
        cd "$runtime_dir"
        tar czf "$output_tarball" include/node/
    )
    info "  Created headers tarball: $output_tarball"
    return 0
}
