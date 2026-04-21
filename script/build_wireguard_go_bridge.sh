#!/bin/sh

# build_wireguard_go_bridge.sh
#
# Builds WireGuardKitGo for the iOS app target.
# The script skips rebuilding when the outputs are already fresh for the
# current Go toolchain and platform settings.

set -eu

log() {
    printf '%s\n' "$*"
}

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=${PROJECT_DIR:-$(CDPATH= cd -- "$script_dir/.." && pwd)}

resolve_wireguard_go_dir() {
    local_dir="$project_root/wireguard-apple/Sources/WireGuardKitGo"
    if [ -d "$local_dir" ]; then
        printf '%s\n' "$local_dir"
        return 0
    fi

    if [ -n "${BUILD_DIR:-}" ]; then
        spm_dir="$BUILD_DIR/SourcePackages/checkouts/wireguard-apple/Sources/WireGuardKitGo"
        if [ -d "$spm_dir" ]; then
            printf '%s\n' "$spm_dir"
            return 0
        fi
    fi

    spm_dir="$project_root/SourcePackages/checkouts/wireguard-apple/Sources/WireGuardKitGo"
    if [ -d "$spm_dir" ]; then
        printf '%s\n' "$spm_dir"
        return 0
    fi

    fail "Unable to locate wireguard-apple/Sources/WireGuardKitGo"
}

wireguard_go_dir=$(resolve_wireguard_go_dir)
out_dir="$wireguard_go_dir/out"
log_file="$out_dir/build_wireguard_go_bridge.log"
stamp_file="$out_dir/.build_wireguard_go_bridge.stamp"

mkdir -p "$out_dir"

GO_BIN=$(command -v go 2>/dev/null || true)
if [ -z "$GO_BIN" ] && [ -x /opt/homebrew/bin/go ]; then
    GO_BIN=/opt/homebrew/bin/go
fi
if [ -z "$GO_BIN" ] && [ -x /usr/local/bin/go ]; then
    GO_BIN=/usr/local/bin/go
fi
[ -n "$GO_BIN" ] || fail "Go toolchain not found in PATH"

GO_VERSION=$("$GO_BIN" version 2>/dev/null || true)
[ -n "$GO_VERSION" ] || fail "Unable to read Go version"

current_stamp="go=${GO_VERSION};platform=${PLATFORM_NAME:-iphoneos};archs=${ARCHS:-arm64};target=${IPHONEOS_DEPLOYMENT_TARGET:-unknown}"

outputs_ready=0
if [ -f "$out_dir/libwg-go.a" ] && [ -f "$out_dir/wireguard-go-version.h" ] && [ -f "$stamp_file" ]; then
    if [ "$(cat "$stamp_file")" = "$current_stamp" ]; then
        if ! find "$wireguard_go_dir" \
            -type f \
            \( -name '*.go' -o -name '*.c' -o -name '*.h' -o -name '*.s' -o -name 'Makefile' -o -name 'go.mod' -o -name 'go.sum' \) \
            -newer "$stamp_file" -print -quit 2>/dev/null | grep -q .; then
            outputs_ready=1
        fi
    fi
fi

if [ "$outputs_ready" -eq 1 ]; then
    log "✅ WireGuardGoBridge is up to date, skipping"
    exit 0
fi

export PATH="$(dirname "$GO_BIN"):$PATH"
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"

cd "$wireguard_go_dir"

jobs=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
make_cmd=${MAKE:-/usr/bin/make}

log "🔨 Building WireGuardGoBridge in $wireguard_go_dir"
log "   Go: $GO_VERSION"
log "   Jobs: $jobs"

if ! "$make_cmd" -j"$jobs" >"$log_file" 2>&1; then
    printf '%s\n' "=== WireGuardGoBridge build failed ===" >&2
    ls -la "$out_dir" >&2 || true
    tail -n 200 "$log_file" >&2 || true
    exit 1
fi

printf '%s\n' "$current_stamp" > "$stamp_file"
rm -f "$log_file"
log "✅ WireGuardGoBridge built successfully"
