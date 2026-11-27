#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/tty-session.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
# スタックの登録を開いた状態で流しても、fd の数を比べるケースが通る。
# 流し終えたあとは、正常に終わったプロセスの名前を取り下げてあり、SIGKILL したプロセスの名前はケースが消すので、整数の名前は 1 つも残らない。
# 保存先は、ランナー（tests/run-one.sh）が渡したものを使う。時間切れのときに、run-one.sh がそこからスタックを採るため。
# 渡されていない（このファイルを直接流した）ときだけ、テスト専用の場所を作る。
stack_dir=${SQUAD_KIT_TEST_STACK_DIR:-}
if [[ -z $stack_dir ]]; then stack_dir=$test_dir/stacks; mkdir "$stack_dir"; fi
SQUAD_KIT_TEST_STACK_DIR=$stack_dir python3 -I -B "$root/tests/tty-session-cases.py" "$root" "$test_dir"
for name in $(ls -A "$stack_dir"); do
	if [[ $name =~ ^[0-9]+$ ]]; then echo "FAIL tty-session: 終わったプロセスの名前が残っている: $name" >&2; exit 1; fi
done
echo 'PASS tty-session: 終わったプロセスのスタックの名前が残らない'
