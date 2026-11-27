#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/tty-session.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
# スタックの登録を開いた状態で流しても、fd の数を比べるケースが通る。
# 流し終えたあとは、正常に終わったプロセスの登録を取り下げてあるので、残るのはケースが SIGKILL したプロセスのファイルだけになる。
mkdir "$test_dir/stacks" "$test_dir/work"
SQUAD_KIT_TEST_STACK_DIR="$test_dir/stacks" python3 -I -B "$root/tests/tty-session-cases.py" "$root" "$test_dir/work"
touch "$test_dir/work/sigkilled-pids"
for name in $(ls -A "$test_dir/stacks"); do
	grep -qxF -- "$name" "$test_dir/work/sigkilled-pids" || { echo "FAIL tty-session: 正常に終わったプロセスの登録が残っている: $name" >&2; exit 1; }
done
echo 'PASS tty-session: 正常に終わったプロセスのスタックの登録が残らない'
