#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
assets_dir="$project_root/TurnBridge/DeployAssets"
release_url="https://github.com/anton48/vk-turn-proxy/releases/download/srtp-build440"

mkdir -p "$assets_dir"

fetch_one() {
    arch="$1"
    expected="$2"
    output="$assets_dir/srtp-linux-$arch"
    curl --fail --location --retry 3 --output "$output" "$release_url/server-linux-$arch"
    actual=$(shasum -a 256 "$output" | awk '{print $1}')
    if [ "$actual" != "$expected" ]; then
        printf 'SRTP asset checksum mismatch for %s\n' "$arch" >&2
        exit 1
    fi
    chmod 0644 "$output"
}

fetch_one amd64 52aecde3b7b161789c6275abbba775a98600b786305ddb02c1880db10dae734c
fetch_one arm64 a69262b6e2a7019bbff19be74309adfd0a8de0e4014b25f4ecd90132afdadde8
