#!/bin/bash
# Native Node module rebuilds for the copied VS Code/Electron payload.
#
# WorkBuddy ships app.asar + app.asar.unpacked. The unpacked directory
# contains pre-compiled native modules for macOS (Mach-O) and Windows (PE)
# that CANNOT run on Linux. We must:
#   1. Delete all macOS/Windows-only binaries and platform packages
#   2. Rebuild critical native modules from npm source for Linux/Electron
#   3. Install Linux platform-specific packages (e.g. @lydell/node-pty-linux-x64)
#   4. Replace CLI vendor binaries (ripgrep) with Linux versions
#
# Audit date: 2026-05-10
# See docs/porting-notes.md and the native module audit for full details.

native_module_report() {
    local search_dir="$1"
    find "$search_dir" -name "*.node" -o -name "*.so" -o -name "*.dylib" 2>/dev/null \
        | grep -v '__pycache__' | sort || true
}

# ---------------------------------------------------------------------------
# Phase 1: Delete ALL non-Linux platform binaries and packages
# ---------------------------------------------------------------------------
purge_all_non_linux_artifacts() {
    local app_dir="$1"

    info "=== Phase 1: Purging all non-Linux platform artifacts ==="

    # -- macOS platform packages (@lydell/node-pty-darwin-*) in node_modules --
    rm -rf "$app_dir/node_modules/@lydell/node-pty-darwin-arm64" 2>/dev/null || true
    rm -rf "$app_dir/node_modules/@lydell/node-pty-darwin-x64" 2>/dev/null || true
    rm -rf "$app_dir/node_modules/@lydell/node-pty-win32-arm64" 2>/dev/null || true
    rm -rf "$app_dir/node_modules/@lydell/node-pty-win32-x64" 2>/dev/null || true
    info "  Removed @lydell/node-pty macOS/Windows platform packages from node_modules"

    # -- macOS platform packages (@lydell/node-pty-darwin-*) in cli/node_modules --
    rm -rf "$app_dir/cli/node_modules/@lydell/node-pty-darwin-arm64" 2>/dev/null || true
    rm -rf "$app_dir/cli/node_modules/@lydell/node-pty-darwin-x64" 2>/dev/null || true
    rm -rf "$app_dir/cli/node_modules/@lydell/node-pty-win32-arm64" 2>/dev/null || true
    rm -rf "$app_dir/cli/node_modules/@lydell/node-pty-win32-x64" 2>/dev/null || true
    info "  Removed @lydell/node-pty macOS/Windows platform packages from cli/node_modules"

    # -- Windows-only VS Code modules --
    rm -rf "$app_dir/node_modules/windows-foreground-love" 2>/dev/null || true
    rm -rf "$app_dir/node_modules/@vscode/windows-mutex" 2>/dev/null || true
    rm -rf "$app_dir/node_modules/@vscode/windows-process-tree" 2>/dev/null || true
    rm -rf "$app_dir/node_modules/@vscode/windows-registry" 2>/dev/null || true
    info "  Removed Windows-only VS Code modules"

    # -- fsevents (macOS-only filesystem events, Linux uses inotify) --
    find "$app_dir" -type d -name "fsevents" -prune -exec rm -rf {} + 2>/dev/null || true
    info "  Removed fsevents (macOS-only)"

    # -- @tencent/docs-engine (private module, only has darwin-arm64 binaries) --
    # This is Tencent's internal document engine SDK. It ships only macOS arm64
    # binaries (libeditor_sdk_ffi.dylib ~206MB + start_server_addon.node).
    # Not available on npm, cannot be rebuilt for Linux.
    # This affects Tencent Docs integration only, not core AI coding functionality.
    if [ -d "$app_dir/node_modules/@tencent/docs-engine/lib/darwin-arm64" ]; then
        rm -rf "$app_dir/node_modules/@tencent/docs-engine/lib/darwin-arm64"
        info "  Removed @tencent/docs-engine macOS binaries (private module, not available for Linux)"
    fi

    # -- node-pty prebuilds: remove ALL non-Linux platform prebuilds --
    find "$app_dir/node_modules" -path "*/prebuilds/darwin-*" -type d -prune -exec rm -rf {} + 2>/dev/null || true
    find "$app_dir/node_modules" -path "*/prebuilds/win32-*" -type d -prune -exec rm -rf {} + 2>/dev/null || true
    info "  Removed all darwin-*/win32-* prebuilds directories"

    # -- better-sqlite3 macOS prebuilts --
    rm -rf "$app_dir/node_modules/better-sqlite3/bin/darwin-"* 2>/dev/null || true
    info "  Removed better-sqlite3 macOS prebuild bins"

    # -- CLI vendor: Windows sandbox binaries --
    rm -f "$app_dir/cli/vendor/sandbox/sandbox-cli.exe" 2>/dev/null || true
    rm -f "$app_dir/cli/vendor/sandbox/sandbox_ffi.dll" 2>/dev/null || true
    rm -f "$app_dir/cli/vendor/sandbox/tsbx.dll" 2>/dev/null || true
    rm -f "$app_dir/cli/vendor/sandbox/tsbx_sdk.dll" 2>/dev/null || true
    info "  Removed Windows sandbox DLLs/EXEs from cli/vendor"

    # -- CLI vendor: macOS ripgrep binary --
    if [ -d "$app_dir/cli/vendor/ripgrep/x64-darwin" ]; then
        rm -rf "$app_dir/cli/vendor/ripgrep/x64-darwin"
        info "  Removed macOS ripgrep binary from cli/vendor"
    fi

    # -- CLI vendor: macOS sandbox-cli binary --
    if [ -f "$app_dir/cli/vendor/sandbox/sandbox-cli" ]; then
        local desc=""
        if command -v file >/dev/null 2>&1; then
            desc="$(file "$app_dir/cli/vendor/sandbox/sandbox-cli" 2>/dev/null || true)"
        fi
        case "$desc" in
            *Mach-O*|*"")
                rm -f "$app_dir/cli/vendor/sandbox/sandbox-cli"
                info "  Removed macOS sandbox-cli binary from cli/vendor"
                ;;
        esac
    fi
}

# ---------------------------------------------------------------------------
# Phase 2: Deep scan and remove any remaining Mach-O / PE binaries
# ---------------------------------------------------------------------------
purge_remaining_foreign_binaries() {
    local app_dir="$1"
    local native_file description

    info "=== Phase 2: Deep scan for remaining non-Linux binaries ==="

    command -v file >/dev/null 2>&1 || {
        warn "  'file' command not available; skipping deep binary scan"
        return 0
    }

    local removed=0
    while IFS= read -r native_file; do
        description="$(file "$native_file" 2>/dev/null || true)"
        case "$description" in
            *Mach-O*)
                warn "  Removing Mach-O binary: $native_file"
                rm -f "$native_file"
                ((removed++)) || true
                ;;
            *"PE32"*|*"PE32+"*|*"MS Windows"*)
                warn "  Removing Windows PE binary: $native_file"
                rm -f "$native_file"
                ((removed++)) || true
                ;;
        esac
    done < <(find "$app_dir" \( -name "*.node" -o -name "*.dylib" -o -name "*.so" -o -name "*.dll" \) -type f 2>/dev/null | sort || true)

    # Also check executables without extensions
    while IFS= read -r native_file; do
        [ -x "$native_file" ] || continue
        description="$(file "$native_file" 2>/dev/null || true)"
        case "$description" in
            *Mach-O*)
                warn "  Removing Mach-O executable: $native_file"
                rm -f "$native_file"
                ((removed++)) || true
                ;;
        esac
    done < <(find "$app_dir/cli/vendor" -type f 2>/dev/null | sort || true)

    if [ "$removed" -gt 0 ]; then
        info "  Removed $removed remaining non-Linux binaries"
    else
        info "  No remaining non-Linux binaries found (clean)"
    fi
}

# ---------------------------------------------------------------------------
# Phase 3: Rebuild native modules from npm source
# ---------------------------------------------------------------------------

read_module_version() {
    local app_dir="$1"
    local module_name="$2"
    local pkg="$app_dir/node_modules/$module_name/package.json"
    [ -f "$pkg" ] || return 1
    node -e 'process.stdout.write(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).version||"")' "$pkg"
}

build_native_module_fresh() {
    local app_dir="$1"
    local module_name="$2"
    local module_version="$3"
    local allow_fail="${4:-0}"

    local build_dir="$WORK_DIR/native-build/${module_name//@/_}_${module_version}"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    local rc=0
    info "  Building $module_name@$module_version from source for Electron $ELECTRON_VERSION"

    # Run rebuild in a subshell.  Use || to capture the exit code safely
    # under set -e (which is active via the caller's set -Eeuo pipefail).
    (
        cd "$build_dir"
        echo '{"private":true}' > package.json

        # Install the Electron npm package so @electron/rebuild can resolve the version.
        # (--ignore-scripts skips the runtime download — we already have it.)
        npm install "electron@$ELECTRON_VERSION" --save-dev --ignore-scripts --no-audit --no-fund 2>&1 >/dev/null

        # Install the module's full source
        npm install "$module_name@$module_version" --ignore-scripts --no-audit --no-fund 2>&1 >/dev/null

        # Rebuild for the target Electron
        # If ELECTRON_HEADERS_DIR is set (extracted from runtime), use it directly.
        # Otherwise fall back to disturl-based header download.
        if [ -n "${ELECTRON_HEADERS_DIR:-}" ] && [ -d "$ELECTRON_HEADERS_DIR" ]; then
            # Use local headers extracted from the Electron runtime
            # (Electron v36+ no longer publishes node-{version}-headers.tar.gz)
            export ELECTRON_HEADERS_URL="$ELECTRON_HEADERS_DIR"
            npx --yes @electron/rebuild \
                -v "$ELECTRON_VERSION" \
                --force \
                --dist-url "$ELECTRON_HEADERS_DIR" \
                --only "$module_name" 2>&1
        else
            npm_config_disturl="${ELECTRON_HEADERS_URL:-https://npmmirror.com/mirrors/electron}" \
            NPM_CONFIG_DISTURL="${ELECTRON_HEADERS_URL:-https://npmmirror.com/mirrors/electron}" \
            npx --yes @electron/rebuild \
                -v "$ELECTRON_VERSION" \
                --force \
                --dist-url "${ELECTRON_HEADERS_URL:-https://npmmirror.com/mirrors/electron}" \
                --only "$module_name" 2>&1
        fi
    ) || rc=$?

    if [ "$rc" -ne 0 ]; then
        if [ "$allow_fail" -eq 1 ]; then
            warn "  Failed to build $module_name@$module_version (optional, continuing)"
            return 0
        else
            error "Failed to build $module_name@$module_version"
        fi
    fi

    # Verify at least one .node was produced
    local built_path="$build_dir/node_modules/$module_name"
    local node_count
    node_count="$(find "$built_path" -name '*.node' -type f 2>/dev/null | wc -l)"
    if [ "$node_count" -eq 0 ] && [ "$allow_fail" -eq 0 ]; then
        error "No .node files produced for $module_name@$module_version"
    fi

    # Copy the freshly built module back into the app
    local target_path="$app_dir/node_modules/$module_name"
    rm -rf "$target_path"
    mkdir -p "$(dirname "$target_path")"
    cp -a "$built_path" "$target_path"
    info "  Installed fresh $module_name@$module_version (${node_count} native files)"
}

rebuild_critical_modules() {
    local app_dir="$1"

    info "=== Phase 3: Rebuilding native modules from source ==="
    info "  Target: Electron $ELECTRON_VERSION | Headers: ${ELECTRON_HEADERS_URL:-https://npmmirror.com/mirrors/electron}"

    local module_name module_version

    # --- Critical modules (build failure = continue with prebuilds) ---
    # node-pty and better-sqlite3 are handled in Phase 4 (platform packages
    # and patched-header rebuild), so Phase 3 skips them to avoid wasting
    # time on @electron/rebuild that will fail without published headers.
    local -a critical_modules=()

    for module_name in "${critical_modules[@]}"; do
        module_version="$(read_module_version "$app_dir" "$module_name" 2>/dev/null || true)"
        if [ -z "$module_version" ]; then
            warn "  Module $module_name not found in app; skipping"
            continue
        fi
        build_native_module_fresh "$app_dir" "$module_name" "$module_version" 1
    done

    # --- Optional modules (build failure = warning only) ---
    local -a optional_modules=(
        "native-keymap"
        "native-watchdog"
        "@vscode/spdlog"
        "@vscode/sqlite3"
        "kerberos"
    )

    for module_name in "${optional_modules[@]}"; do
        module_version="$(read_module_version "$app_dir" "$module_name" 2>/dev/null || true)"
        if [ -z "$module_version" ]; then
            # These may be inside app.asar, not in unpacked; that's expected
            continue
        fi
        build_native_module_fresh "$app_dir" "$module_name" "$module_version" 1
    done
}

# ---------------------------------------------------------------------------
# Phase 4: Install Linux platform packages
# ---------------------------------------------------------------------------

refresh_npm_package() {
    local app_dir="$1"
    local package_name="$2"
    local package_path="$app_dir/node_modules/$package_name"
    local version build_dir source_path

    [ -f "$package_path/package.json" ] || return 0
    version="$(node -e 'const p=require(process.argv[1]); process.stdout.write(String(p.version || ""));' "$package_path/package.json")"
    [ -n "$version" ] || return 0

    build_dir="$WORK_DIR/platform-packages/${package_name//@/_}"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    info "  Refreshing platform package $package_name@$version"
    (
        cd "$build_dir"
        npm init -y >/dev/null 2>&1
        npm install "$package_name@$version" --no-audit --no-fund
    )

    source_path="$build_dir/node_modules/$package_name"
    [ -d "$source_path" ] || error "Failed to install $package_name@$version"
    rm -rf "$package_path"
    mkdir -p "$(dirname "$package_path")"
    cp -a "$source_path" "$package_path"
}

install_lydell_node_pty_linux() {
    local target_dir="$1"
    local lydell_pkg="$target_dir/node_modules/@lydell/node-pty/package.json"
    local version build_dir linux_pkg_name

    [ -f "$lydell_pkg" ] || return 0
    version="$(node -e 'const p=require(process.argv[1]); process.stdout.write(String(p.version || ""));' "$lydell_pkg")"
    [ -n "$version" ] || return 0

    case "$ARCH" in
        x86_64) linux_pkg_name="@lydell/node-pty-linux-x64" ;;
        aarch64) linux_pkg_name="@lydell/node-pty-linux-arm64" ;;
        *) warn "  No @lydell/node-pty Linux platform package for $ARCH"; return 0 ;;
    esac

    build_dir="$WORK_DIR/lydell-pty-$(basename "$target_dir")"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    info "  Installing $linux_pkg_name@$version"
    (
        cd "$build_dir"
        npm init -y >/dev/null 2>&1
        npm install "$linux_pkg_name@$version" --no-audit --no-fund 2>&1
    ) || {
        warn "  Failed to install $linux_pkg_name@$version (optional, continuing)"
        return 0
    }

    local source_path="$build_dir/node_modules/$linux_pkg_name"
    if [ -d "$source_path" ]; then
        local target_path="$target_dir/node_modules/$linux_pkg_name"
        rm -rf "$target_path"
        mkdir -p "$(dirname "$target_path")"
        cp -a "$source_path" "$target_path"
        info "  Installed $linux_pkg_name@$version"
    fi
}

install_cli_ripgrep_linux() {
    local app_dir="$1"
    local ripgrep_vendor="$app_dir/cli/vendor/ripgrep"

    [ -d "$ripgrep_vendor" ] || return 0

    local linux_dir
    case "$ARCH" in
        x86_64) linux_dir="x64-linux" ;;
        aarch64) linux_dir="arm64-linux" ;;
        *) warn "  No ripgrep binary for $ARCH"; return 0 ;;
    esac

    local build_dir="$WORK_DIR/cli-ripgrep"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    info "  Installing Linux ripgrep for CLI vendor"
    (
        cd "$build_dir"
        npm init -y >/dev/null 2>&1
        npm install @vscode/ripgrep --no-audit --no-fund 2>&1
    ) || {
        warn "  Failed to install @vscode/ripgrep for CLI (optional, continuing)"
        return 0
    }

    # @vscode/ripgrep >= 1.14 installs binary in an architecture-specific sub-package
    local rg_bin
    rg_bin="$(node -e "try { console.log(require('$build_dir/node_modules/@vscode/ripgrep').rgPath) } catch(e) {}" 2>/dev/null)"
    
    # Fallback if that failed
    if [ -z "$rg_bin" ] || [ ! -x "$rg_bin" ]; then
        rg_bin="$build_dir/node_modules/@vscode/ripgrep/bin/rg"
    fi

    if [ -x "$rg_bin" ]; then
        mkdir -p "$ripgrep_vendor/$linux_dir"
        cp "$rg_bin" "$ripgrep_vendor/$linux_dir/rg"
        chmod +x "$ripgrep_vendor/$linux_dir/rg"
        info "  Installed Linux rg binary to cli/vendor/ripgrep/$linux_dir/"

        # Also check for ripgrep.node binding
        local rg_node
        rg_node="$(find "$build_dir/node_modules/@vscode/ripgrep" -name "ripgrep.node" -type f 2>/dev/null | head -1)"
        if [ -n "$rg_node" ]; then
            cp "$rg_node" "$ripgrep_vendor/$linux_dir/ripgrep.node"
            info "  Installed Linux ripgrep.node to cli/vendor/ripgrep/$linux_dir/"
        fi
    else
        warn "  Could not find rg binary after installing @vscode/ripgrep"
    fi
}

install_linux_platform_packages() {
    local app_dir="$1"

    info "=== Phase 4: Installing Linux platform packages ==="

    # Refresh @vscode/ripgrep and @parcel/watcher in main node_modules
    refresh_npm_package "$app_dir" "@vscode/ripgrep"
    refresh_npm_package "$app_dir" "@parcel/watcher"

    # Install @lydell/node-pty Linux package in node_modules
    install_lydell_node_pty_linux "$app_dir"

    # Install @lydell/node-pty Linux package in cli/node_modules
    if [ -d "$app_dir/cli/node_modules/@lydell/node-pty" ]; then
        install_lydell_node_pty_linux "$app_dir/cli"
    fi

    # Ensure @lydell/node-pty-linux-x64 is also in the top-level node_modules
    # even if @lydell/node-pty main package lives inside app.asar (packed).
    # The sidecar process requires it from within the asar, and the patch
    # script registers it as an unpacked entry during repack.
    local linux_pkg="$app_dir/node_modules/@lydell/node-pty-linux-x64"
    if [ ! -d "$linux_pkg" ]; then
        # Try to copy from cli/node_modules if available
        local cli_pkg="$app_dir/cli/node_modules/@lydell/node-pty-linux-x64"
        if [ -d "$cli_pkg" ]; then
            mkdir -p "$(dirname "$linux_pkg")"
            cp -a "$cli_pkg" "$linux_pkg"
            info "  Copied @lydell/node-pty-linux-x64 from cli/ to top-level node_modules"
        else
            # Install fresh from npm
            local version="1.2.0-beta.12"
            local pkg_name
            case "$ARCH" in
                x86_64) pkg_name="@lydell/node-pty-linux-x64" ;;
                aarch64) pkg_name="@lydell/node-pty-linux-arm64" ;;
                *) pkg_name="" ;;
            esac
            if [ -n "$pkg_name" ]; then
                local build_dir="$WORK_DIR/lydell-pty-toplevel"
                rm -rf "$build_dir"
                mkdir -p "$build_dir"
                (
                    cd "$build_dir"
                    npm init -y >/dev/null 2>&1
                    npm install "$pkg_name@$version" --no-audit --no-fund 2>&1
                ) || true
                local src_path="$build_dir/node_modules/$pkg_name"
                if [ -d "$src_path" ]; then
                    mkdir -p "$(dirname "$linux_pkg")"
                    cp -a "$src_path" "$linux_pkg"
                    info "  Installed $pkg_name@$version to top-level node_modules"
                fi
            fi
        fi
    fi

    # --- better-sqlite3: compile from source against patched Node.js headers ---
    # Electron v37+ doesn't publish the standard node-*-headers.tar.gz tarball
    # needed by node-gyp.  Workaround: download the stock Node.js 22.21.1
    # headers (same Node major as Electron 37's runtime), patch the
    # NODE_MODULE_VERSION to 136 (= Electron 37 ABI), and build against them.
    local bsql3_pkg="$app_dir/node_modules/better-sqlite3"
    if [ -f "$bsql3_pkg/package.json" ]; then
        local bsql3_version
        bsql3_version="$(node -e 'const p=require(process.argv[1]); process.stdout.write(String(p.version || ""));' "$bsql3_pkg/package.json" 2>/dev/null || true)"
        if [ -n "$bsql3_version" ]; then
            local headers_dir="$WORK_DIR/electron-headers-patched"
            # Download + patch headers only once per build
            if [ ! -f "$headers_dir/.patched" ]; then
                prepare_patched_electron_headers "$headers_dir" || true
            fi
            if [ -f "$headers_dir/.patched" ]; then
                info "  Rebuilding better-sqlite3@$bsql3_version against patched headers (auto-detected ABI)"
                (
                    cd "$bsql3_pkg"
                    npm_config_nodedir="$headers_dir" \
                        npx --yes node-gyp rebuild --release 2>&1
                ) || warn "  Failed to rebuild better-sqlite3 (continuing with prebuild)"
            else
                warn "  Cannot prepare headers — installing better-sqlite3 with npm prebuild"
                # Fallback: try npm install with scripts (may fail if ABI mismatches)
                local bsql3_build="$WORK_DIR/bsql3-fallback"
                rm -rf "$bsql3_build"
                mkdir -p "$bsql3_build"
                (
                    cd "$bsql3_build"
                    npm init -y >/dev/null 2>&1
                    npm install "better-sqlite3@$bsql3_version" --no-audit --no-fund 2>&1
                ) || true
                local bsql3_src="$bsql3_build/node_modules/better-sqlite3"
                if [ -d "$bsql3_src" ]; then
                    rm -rf "$bsql3_pkg"
                    cp -a "$bsql3_src" "$bsql3_pkg"
                    info "  Installed better-sqlite3@$bsql3_version with npm prebuild (may not work)"
                fi
            fi
        fi
    fi

    # Install Linux ripgrep for CLI vendor
    install_cli_ripgrep_linux "$app_dir"
}
# ---------------------------------------------------------------------------
# verify_native_modules — sanity-check that critical native modules exist
# and are Linux ELF binaries (not stale Mach-O/PE).
# This is the last gate before declaring the rebuild complete.
# ---------------------------------------------------------------------------
verify_native_modules() {
    local app_dir="$1"
    local errors=0

    # List of critical .node files we expect to be valid ELF on Linux
    local -a checks=(
        "$app_dir/node_modules/better-sqlite3/build/Release/better_sqlite3.node"
        "$app_dir/node_modules/@lydell/node-pty/prebuilds/linux-x64/pty.node"
    )

    # Also check for node-pty (non-@lydell variant) as fallback
    if [ -f "$app_dir/node_modules/node-pty/build/Release/pty.node" ]; then
        checks+=("$app_dir/node_modules/node-pty/build/Release/pty.node")
    fi

    command -v file >/dev/null 2>&1 || { info "  (skip ELF check: 'file' command not available)"; return 0; }

    for node_file in "${checks[@]}"; do
        if [ ! -f "$node_file" ]; then
            warn "  Missing native module: ${node_file#${app_dir}/}"
            ((errors++)) || true
            continue
        fi
        local desc
        desc="$(file "$node_file" 2>/dev/null || true)"
        case "$desc" in
            *ELF*)
                info "  OK: ${node_file#${app_dir}/}"
                ;;
            *Mach-O*)
                warn "  STALE Mach-O binary: ${node_file#${app_dir}/}"
                ((errors++)) || true
                ;;
            *PE32*|*"MS Windows"*)
                warn "  STALE Windows binary: ${node_file#${app_dir}/}"
                ((errors++)) || true
                ;;
            *)
                warn "  Unknown format: ${node_file#${app_dir}/} — ${desc}"
                ((errors++)) || true
                ;;
        esac
    done

    if [ "$errors" -gt 0 ]; then
        warn "  Native module verification: ${errors} issue(s) found"
    else
        info "  Native module verification: all critical modules OK"
    fi
}

# ---------------------------------------------------------------------------
# Main entry point: rebuild_native_modules
# ---------------------------------------------------------------------------
rebuild_native_modules() {
    local app_dir="$1"

    [ -d "$app_dir/node_modules" ] || {
        warn "No node_modules directory found; skipping native rebuild"
        return 0
    }

    info "╔════════════════════════════════════════════════════╗"
    info "║  WorkBuddy Native Module Rebuild for Linux        ║"
    info "╚════════════════════════════════════════════════════╝"
    info ""
    info "Native modules BEFORE cleanup:"
    native_module_report "$app_dir" >&2
    info ""

    # Phase 1: Delete all non-Linux binaries
    purge_all_non_linux_artifacts "$app_dir"
    info ""

    # Phase 2: Deep scan for any missed Mach-O / PE binaries
    purge_remaining_foreign_binaries "$app_dir"
    info ""

    # Phase 3: Rebuild native modules from npm source
    rebuild_critical_modules "$app_dir"
    info ""

    # Phase 4: Install Linux platform packages
    install_linux_platform_packages "$app_dir"
    info ""

    # Final verification
    info "Native modules AFTER rebuild:"
    native_module_report "$app_dir" >&2
    verify_native_modules "$app_dir"
    info ""
    info "Native module rebuild complete."
}
