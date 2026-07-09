#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
server_dir="$project_root/third_party/wdtt-server"
assets_dir="$project_root/TurnBridge/DeployAssets"

GO_BIN=$(command -v go 2>/dev/null || true)
if [ -z "$GO_BIN" ] && [ -x /opt/homebrew/bin/go ]; then
    GO_BIN=/opt/homebrew/bin/go
fi
if [ -z "$GO_BIN" ] && [ -x /usr/local/bin/go ]; then
    GO_BIN=/usr/local/bin/go
fi
[ -n "$GO_BIN" ] || {
    printf '%s\n' "Go toolchain not found in PATH" >&2
    exit 1
}

mkdir -p "$assets_dir"

build_one() {
    arch="$1"
    out="$assets_dir/wdtt-server-linux-$arch"
    printf 'Building WDTT server asset: linux/%s\n' "$arch"
    (
        cd "$server_dir"
        GOOS=linux GOARCH="$arch" CGO_ENABLED=0 "$GO_BIN" build \
            -trimpath \
            -ldflags "-s -w" \
            -o "$out" \
            .
    )
    chmod 0644 "$out"
}

build_one amd64
build_one arm64
