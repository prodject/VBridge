#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
assets_dir="$project_root/TurnBridge/DeployAssets"
plus_server_dir="$project_root/third_party/wdtt-server"
legacy_repo_url="https://github.com/amurcanov/proxy-turn-vk-android"
legacy_repo_tag="v1.2.4"

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
    server_dir="$1"
    out_prefix="$2"
    arch="$3"
    out="$assets_dir/$out_prefix-linux-$arch"
    printf 'Building %s asset: linux/%s\n' "$out_prefix" "$arch"
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

prepare_legacy_repo() {
    worktree=$(mktemp -d "${TMPDIR:-/tmp}/wdtt-src.XXXXXX")
    git clone --depth 1 --branch "$legacy_repo_tag" "$legacy_repo_url" "$worktree" >&2
    printf '%s\n' "$worktree/app/src/main/assets/linux-server"
}

stable_server_dir=$(prepare_legacy_repo)

build_one "$stable_server_dir" "wdtt" amd64
build_one "$stable_server_dir" "wdtt" arm64
build_one "$plus_server_dir" "wdtt-plus" amd64
build_one "$plus_server_dir" "wdtt-plus" arm64
