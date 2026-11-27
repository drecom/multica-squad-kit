#!/usr/bin/env bash
# scripts/manifest.sh が、追跡外の Python の実行の生成物（__pycache__ と *.pyc）を一覧に入れず、同じ入力から同じ一覧を作ることを確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/manifest-test.XXXXXX")
trap 'rm -rf "$work" "$work.before"' EXIT
mkdir -p "$work/scripts" "$work/lib" "$work/tmp"
cp "$root/scripts/manifest.sh" "$work/scripts/"
printf 'a\n' >"$work/lib/a.py"
printf 'b\n' >"$work/b.txt"
(cd "$work" && bash scripts/manifest.sh)
cp "$work/MANIFEST" "$work.before"
# 実行で生まれる生成物と一時ファイルは、入れない。
mkdir -p "$work/lib/__pycache__" "$work/tests/__pycache__"
printf 'x\n' >"$work/lib/__pycache__/a.cpython-314.pyc"
printf 'x\n' >"$work/tests/__pycache__/t.cpython-314.pyc"
printf 'x\n' >"$work/lib/stray.pyc"
printf 'x\n' >"$work/tmp/scratch"
(cd "$work" && bash scripts/manifest.sh)
cmp "$work.before" "$work/MANIFEST"
! grep -q 'pyc\|__pycache__\|tmp/' "$work/MANIFEST"
grep -q '  ./lib/a.py$' "$work/MANIFEST"
grep -q '  ./b.txt$' "$work/MANIFEST"
echo 'PASS manifest: __pycache__・*.pyc・tmp を一覧に入れず、追跡するファイルだけから同じ一覧を作る'
