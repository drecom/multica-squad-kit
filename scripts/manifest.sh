#!/usr/bin/env bash
# git の管理領域と一時ファイル、Python の実行で生まれる __pycache__ と *.pyc（.gitignore と同じ）を除き、配布する原本のハッシュを作る。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p tmp
while IFS= read -r -d '' file; do shasum -a 256 "$file"; done < <(find . \( -path ./.git -o -path ./tmp -o -name __pycache__ \) -prune -o -type f ! -path ./MANIFEST ! -name '*.pyc' -print0 | LC_ALL=C sort -z) >tmp/manifest.new
mv tmp/manifest.new MANIFEST
