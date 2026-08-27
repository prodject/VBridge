#!/bin/sh
set -eu

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 /path/to/App.app [/path/to/Extension.appex ...]" >&2
  exit 64
fi

dump_target() {
  target="$1"
  echo "== $target =="

  if [ ! -e "$target" ]; then
    echo "missing"
    echo
    return
  fi

  if ! codesign -d --entitlements :- "$target" 2>/tmp/vbridge-entitlements.err; then
    cat /tmp/vbridge-entitlements.err >&2
    echo
    return 1
  fi | plutil -p -

  echo
}

for target in "$@"; do
  dump_target "$target"
done
