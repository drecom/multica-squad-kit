#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/tty-session.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
python3 -I -B "$root/tests/tty-session-cases.py" "$root" "$test_dir"
