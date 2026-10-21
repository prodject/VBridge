#!/bin/sh
set -eu
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_directory=$(mktemp -d "${TMPDIR:-/tmp}/vbridge-link-tests.XXXXXXXX")
trap 'rm -rf "$test_directory"' EXIT HUP INT TERM
cat "$project_root/TurnBridge/ExternalClientLinks.swift" "$project_root/script/tests/ExternalClientLinksTests.swift" > "$test_directory/main.swift"
swift "$test_directory/main.swift"
