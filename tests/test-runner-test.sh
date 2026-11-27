#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/test-runner.XXXXXX")
# 標準エラーを err に向けたまま止まっても、trap が err 自身へ書き足し続けないよう、元の標準エラーを控えて出す。
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&8; fi; rm -rf -- "$test_dir"' EXIT
: >"$test_dir/out"
: >"$test_dir/err"

# 小さな原本のコピーを使い、本物のテストの再帰実行や一覧の書き換えを避ける。
kit="$test_dir/kit"
fixtures="$test_dir/fixtures with spaces"
mkdir -p "$kit/tests" "$fixtures"
cp "$root/tests/run.sh" "$root/tests/run-one.sh" "$root/tests/run-hook.sh" "$root/tests/stop-session.py" "$root/tests/tty-session.py" "$kit/tests/"
for name in project project-followup squad-dispatch-pick squad-dependabot-merge; do
	printf ':\n' >"$kit/tests/$name-test.sh"
done
printf '# 小さな原本の重み\ntests/project-test.sh 10\n\ntests/squad-dependabot-merge-test.sh 40\n' >"$kit/tests/test-weights"
export TEST_RUNNER_KIT="$kit" TEST_RUNNER_STATE="$test_dir/state"
# CI のシャードの指定が、ここで流す小さな走らせ役へ漏れないようにする（シャードの指定は各ケースで渡す）。
unset SQUAD_KIT_TEST_SHARD
cat >"$fixtures/a.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
name=$(basename "$0" .sh)
[[ $PWD == "$TEST_RUNNER_KIT" ]]
[[ -z $(ls -A "$HOME") && -z $(ls -A "$TMPDIR") ]]
[[ ! ${BASH_ENV+x} && ! ${SQUAD_KIT_TEST_ERROR_FILE+x} ]]
bash -c '[[ ! ${BASH_ENV+x} && ! ${SQUAD_KIT_TEST_ERROR_FILE+x} ]]'
printf '%s\n%s\n' "$HOME" "$TMPDIR" >"$TEST_RUNNER_STATE/$name.env"
touch "$HOME/marker"
mktemp "$TMPDIR/probe.XXXXXX" >/dev/null
touch "$TEST_RUNNER_STATE/$name.started"
if [[ $TEST_RUNNER_PARALLEL == yes ]]; then
	for ((attempt=0; attempt<500; attempt++)); do
		if [[ -e $TEST_RUNNER_STATE/a.started && -e $TEST_RUNNER_STATE/b.started ]]; then break; fi
		sleep 0.02
	done
	[[ -e $TEST_RUNNER_STATE/a.started && -e $TEST_RUNNER_STATE/b.started ]]
elif [[ $name == a ]]; then
	[[ ! -e $TEST_RUNNER_STATE/b.started ]]
else
	[[ -e $TEST_RUNNER_STATE/a.finished ]]
fi
touch "$TEST_RUNNER_STATE/$name.finished"
echo "PASS fixture: $name"
FIXTURE
cp "$fixtures/a.sh" "$fixtures/b.sh"
run_suite() {
	local expected=$1 jobs=$2 result=0
	shift 2
	SQUAD_KIT_TEST_JOBS="$jobs" bash "$kit/tests/run.sh" "$@" >"$test_dir/out" 2>"$test_dir/err" || result=$?
	[[ $result == "$expected" ]]
	# 成功・失敗にかかわらず、走らせ役の一時ディレクトリが残らない。
	[[ -z $(find "$kit/tmp" -name 'test-run.*' -type d -print 2>/dev/null) ]]
}
for mode in parallel serial; do
	rm -rf -- "$TEST_RUNNER_STATE"
	mkdir -p "$TEST_RUNNER_STATE"
	if [[ $mode == parallel ]]; then jobs=2; export TEST_RUNNER_PARALLEL=yes
	else jobs=1; export TEST_RUNNER_PARALLEL=no; fi
	run_suite 0 "$jobs" "$fixtures/b.sh" "$fixtures/a.sh"
	grep -qxF "PASS suite: すべてのテスト（2 本、並列 ${jobs}）" "$test_dir/out"
	grep -qxF 'PASS fixture: a' "$test_dir/out"
	grep -qxF 'PASS fixture: b' "$test_dir/out"
	[[ $(sed -n '1p' "$TEST_RUNNER_STATE/a.env") != "$(sed -n '1p' "$TEST_RUNNER_STATE/b.env")" ]]
	[[ $(sed -n '2p' "$TEST_RUNNER_STATE/a.env") != "$(sed -n '2p' "$TEST_RUNNER_STATE/b.env")" ]]
	# ログは引数の順によらず名前順で、ケースの出力が混ざらない。
	[[ $(awk '/^==== PASS/ {print; getline; print}' "$test_dir/out" | grep '^PASS fixture:') == $'PASS fixture: a\nPASS fixture: b' ]]
	echo "PASS runner: $mode で外のファイルを流し、環境とログを分け、後片付けする"
done

# HOME の設定からバージョンを決める python3 の shim でも、空の HOME のテストから動く。
mkdir -p "$test_dir/shim" "$test_dir/real python" "$test_dir/real-home"
touch "$test_dir/real-home/.tool-versions"
# 走らせ役は python3 -c で新しいセッションやグループを作るので、実体を尋ねる -c と -I は、shim を通さない本物の python3 へ渡す。
TEST_RUNNER_SYSTEM_PYTHON=$(command -v python3)
export TEST_RUNNER_SYSTEM_PYTHON
cat >"$test_dir/real python/python3" <<'STUB'
#!/usr/bin/env bash
if [[ ${1:-} == -c && ${2:-} == 'import sys; print(sys.executable)' ]]; then printf '%s\n' "$0"
elif [[ ${1:-} == -c || ${1:-} == -I ]]; then exec "$TEST_RUNNER_SYSTEM_PYTHON" "$@"
else printf 'REAL %s\n' "$*"; fi
STUB
cat >"$test_dir/shim/python3" <<'STUB'
#!/usr/bin/env bash
[[ -e $HOME/.tool-versions ]] || { echo 'No version is set for python3' >&2; exit 126; }
exec "$TEST_RUNNER_REAL_PYTHON" "$@"
STUB
chmod +x "$test_dir/real python/python3" "$test_dir/shim/python3"
cat >"$fixtures/python.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
[[ $(python3 'with space') == 'REAL with space' ]]
echo 'PASS fixture: python'
FIXTURE
HOME="$test_dir/real-home" PATH="$test_dir/shim:$PATH" TEST_RUNNER_REAL_PYTHON="$test_dir/real python/python3" run_suite 0 1 "$fixtures/python.sh"
grep -qxF 'PASS fixture: python' "$test_dir/out"
echo 'PASS runner: HOME からバージョンを決める python3 の shim でも、本物の HOME で引いた実体を空の HOME のテストへ渡す'

cat >"$fixtures/fail.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
echo 'PASS fixture: before failure'
fail_case() { false; }
fail_case
FIXTURE
cat >"$fixtures/pass.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
echo 'PASS fixture: after failure'
FIXTURE
GITHUB_ACTIONS=true run_suite 1 1 "$fixtures/fail.sh" "$fixtures/pass.sh"
grep -qxF 'PASS fixture: after failure' "$test_dir/out"
grep -qxF "失敗した場所: $fixtures/fail.sh:4: false" "$test_dir/out"
grep -qxF "呼び出し: $fixtures/fail.sh:5: fail_case" "$test_dir/out"
! grep -qF 'パイプの終了コード:' "$test_dir/out"
grep -qxF '直前に通ったケース: PASS fixture: before failure' "$test_dir/out"
grep -qF "::error file=$fixtures/fail.sh,line=4::" "$test_dir/out"
[[ $(grep '^==== ' "$test_dir/out" | head -n 1) == "==== PASS $fixtures/pass.sh"* ]]
[[ $(grep '^==== ' "$test_dir/out" | tail -n 1) == "==== FAIL $fixtures/fail.sh"* ]]
grep -qxF "FAIL suite: 1 本が失敗: $fixtures/fail.sh" "$test_dir/out"
echo 'PASS runner: 失敗しても最後まで流し、失敗のログ・行・コマンド・呼び出し・ケース・注釈を出す'

# パイプの途中の部品が失敗したら、場所の次の行に各部品の終了コードを出す。
cat >"$fixtures/pipeline.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
false | cat
FIXTURE
run_suite 1 1 "$fixtures/pipeline.sh"
grep -qxF "失敗した場所: $fixtures/pipeline.sh:3: cat" "$test_dir/out"
grep -A1 -xF "失敗した場所: $fixtures/pipeline.sh:3: cat" "$test_dir/out" |
	tail -n 1 | grep -qxF 'パイプの終了コード: 1 0'
echo 'PASS runner: パイプの途中の失敗では、失敗した場所の次の行に各部品の終了コードを出す'

# テストが IFS を変えても、終了コードの個数と表示の区切りは変わらない。
for ifs_assignment in "IFS=\$'\\n\\t'" "IFS=''" "IFS=:"; do
	printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' "$ifs_assignment" 'false | cat' >"$fixtures/pipeline-ifs.sh"
	run_suite 1 1 "$fixtures/pipeline-ifs.sh"
	grep -A1 -xF "失敗した場所: $fixtures/pipeline-ifs.sh:4: cat" "$test_dir/out" |
		tail -n 1 | grep -qxF 'パイプの終了コード: 1 0'
	echo "PASS runner: $ifs_assignment でも、失敗した場所の次の行に空白区切りのパイプの終了コードを出す"
	# 単独の失敗に、パイプの終了コードを付けない。
	printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' "$ifs_assignment" 'false' >"$fixtures/single-ifs.sh"
	run_suite 1 1 "$fixtures/single-ifs.sh"
	grep -qxF "失敗した場所: $fixtures/single-ifs.sh:4: false" "$test_dir/out"
	! grep -qF 'パイプの終了コード:' "$test_dir/out"
	echo "PASS runner: $ifs_assignment でも、単独の失敗にパイプの終了コードを付けない"
done

cat >"$fixtures/expected-status.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
set +e
false # 想定内の失敗
status=$?
set -e
[[ $status == 1 ]]
echo 'PASS fixture: expected status checked'
actual_failure() { false; }
actual_failure
FIXTURE
GITHUB_ACTIONS=true run_suite 1 1 "$fixtures/expected-status.sh"
grep -qxF "失敗した場所: $fixtures/expected-status.sh:9: false" "$test_dir/out"
grep -qxF "呼び出し: $fixtures/expected-status.sh:10: actual_failure" "$test_dir/out"
grep -qxF '直前に通ったケース: PASS fixture: expected status checked' "$test_dir/out"
grep -qF "::error file=$fixtures/expected-status.sh,line=9::" "$test_dir/out"
echo 'PASS runner: 想定内の終了コードを確認した後の、本当の失敗の行と呼び出しを出す'

# bash 3.2 は、展開のエラーで EXIT の trap が成功すると 0 で終わる。
cat >"$fixtures/unbound.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
trap ':' EXIT
unset TEST_RUNNER_MISSING_VALUE
echo 'PASS fixture: before expansion error'
printf '%s\n' "$TEST_RUNNER_MISSING_VALUE"
FIXTURE
# bash が出す診断と走らせ役の検出を、呼び出し元のロケールによらず同じ条件で確認する。
LC_ALL=C GITHUB_ACTIONS=true run_suite 1 1 "$fixtures/unbound.sh"
grep -qF "==== FAIL $fixtures/unbound.sh（終了コード 1、" "$test_dir/out"
grep -qxF "失敗した場所: $fixtures/unbound.sh:6: TEST_RUNNER_MISSING_VALUE: unbound variable" "$test_dir/out"
grep -qxF '直前に通ったケース: PASS fixture: before expansion error' "$test_dir/out"
grep -qF "::error file=$fixtures/unbound.sh,line=6::" "$test_dir/out"
echo 'PASS runner: EXIT の trap がある本物の展開のエラーも、失敗の行と場所を出して失敗にする'

# 終了コード 0 の場合の検出を、どちらの OS でも通す。
cat >"$fixtures/reported-unbound.sh" <<'FIXTURE'
#!/usr/bin/env bash
printf '%s: line 7: args[@]: unbound variable\n' "$0" >&2
exit 0
FIXTURE
GITHUB_ACTIONS=true run_suite 1 1 "$fixtures/reported-unbound.sh"
grep -qF "==== FAIL $fixtures/reported-unbound.sh（終了コード 1、" "$test_dir/out"
grep -qxF "失敗した場所: $fixtures/reported-unbound.sh:7: args[@]: unbound variable" "$test_dir/out"
grep -qF "::error file=$fixtures/reported-unbound.sh,line=7::" "$test_dir/out"
echo 'PASS runner: 展開のエラーと同じ形式の行があれば、終了コード 0 でも失敗にする'

cat >"$fixtures/unbound-wording.sh" <<'FIXTURE'
#!/usr/bin/env bash
echo 'expected unbound variable in a captured child error' >&2
echo 'PASS fixture: unbound variable wording'
FIXTURE
run_suite 0 1 "$fixtures/unbound-wording.sh"
grep -qxF 'PASS fixture: unbound variable wording' "$test_dir/out"
echo 'PASS runner: unbound variable という語だけでは失敗にしない'

# 並べ替えが一部だけ出力して失敗しても、その一覧で成功扱いしない。
mkdir -p "$test_dir/bin"
export TEST_RUNNER_REAL_SORT
TEST_RUNNER_REAL_SORT=$(command -v sort)
cat >"$test_dir/bin/sort" <<'FIXTURE'
#!/usr/bin/env bash
if [[ $1 == "$TEST_RUNNER_FAIL_SORT" ]]; then
	printf '%s\0' "$TEST_RUNNER_SORT_PARTIAL"
	echo 'sort: simulated temporary-file error' >&2
	exit 1
fi
exec "$TEST_RUNNER_REAL_SORT" "$@"
FIXTURE
chmod +x "$test_dir/bin/sort"
TEST_RUNNER_SORT_PARTIAL="$fixtures/pass.sh" TEST_RUNNER_FAIL_SORT=-z PATH="$test_dir/bin:$PATH" \
	run_suite 1 1 tests/project-test.sh "$fixtures/fail.sh" "$fixtures/pass.sh"
grep -qxF '起こす順の並べ替えに失敗しました' "$test_dir/err"
[[ ! -s $test_dir/out ]]
echo 'PASS runner: 起こす順の並べ替えが失敗したら、テストを起こさず失敗する'

for fixture in fail pass; do
	TEST_RUNNER_SORT_PARTIAL="$fixtures/pass.sh" TEST_RUNNER_FAIL_SORT=-zu PATH="$test_dir/bin:$PATH" \
		run_suite 1 2 "$fixtures/$fixture.sh" "$fixtures/pass.sh"
	grep -qxF '結果の並べ替えに失敗しました。起こした順で結果を確認します' "$test_dir/err"
	grep -qxF 'PASS fixture: after failure' "$test_dir/out"
	if [[ $fixture == fail ]]; then
		grep -qxF "失敗した場所: $fixtures/fail.sh:4: false" "$test_dir/out"
		grep -qxF "FAIL suite: 1 本が失敗: $fixtures/fail.sh" "$test_dir/out"
	else
		grep -qxF 'FAIL suite: 0 本が失敗:' "$test_dir/out"
	fi
	! grep -q '^PASS suite:' "$test_dir/out"
done
echo 'PASS runner: 結果の並べ替えが失敗しても全ファイルを確認し、全体を失敗にする'

# 明示した exit は ERR の記録がなくても失敗になる。255 でも次を起こす。
printf 'exit 255\n' >"$fixtures/exit.sh"
run_suite 1 1 "$fixtures/exit.sh" "$fixtures/pass.sh"
grep -qF '終了コード 255' "$test_dir/out"
grep -qxF "失敗した場所: $fixtures/exit.sh（記録なし）" "$test_dir/out"
grep -qxF 'PASS fixture: after failure' "$test_dir/out"
echo 'PASS runner: ERR の記録がない exit 255 も失敗とし、次のファイルを流す'

# 起動に成功したように見えて結果がない場合を、コピー内の補助で再現する。
printf 'exit 0\n' >"$kit/tests/run-one.sh"
run_suite 1 2 "$fixtures/pass.sh"
grep -qxF '結果の記録なし: 起こせなかったか途中で止まりました' "$test_dir/out"
grep -qxF "FAIL suite: 1 本が失敗: $fixtures/pass.sh" "$test_dir/out"
cp "$root/tests/run-one.sh" "$kit/tests/run-one.sh"
echo 'PASS runner: 結果を残さないファイルを全体の失敗に数える'

for invalid in '' 0 -1 invalid 1.5; do
	run_suite 2 "$invalid" "$fixtures/pass.sh"
	grep -qF 'SQUAD_KIT_TEST_JOBS は正の整数にしてください' "$test_dir/err"
	[[ ! -s $test_dir/out ]]
done
echo 'PASS runner: 並列数が正の整数でなければテストを流さず 2 で終わる'

# 時間の上限。別のプロセスグループで子を起こして眠るファイルを、短い上限で止める。
cat >"$fixtures/sleeper.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
echo 'PASS fixture: before timeout'
python3 -c 'import os, sys; os.setpgrp(); os.execvp(sys.argv[1], sys.argv[1:])' sleep 60 &
printf '%s\n' "$!" >"$TEST_RUNNER_STATE/child.pid"
printf '%s\n' "$$" >"$TEST_RUNNER_STATE/test.pid"
sleep 60
FIXTURE
# TERM を無視するファイルは、5 秒の猶予のあと KILL で止める。
sed 's/^set -euo pipefail$/set -euo pipefail\ntrap "" TERM/' "$fixtures/sleeper.sh" >"$fixtures/stubborn.sh"
pid_gone() {
	local pid=$1 attempt
	for ((attempt=0; attempt<50; attempt++)); do
		kill -0 "$pid" 2>/dev/null || return 0
		sleep 0.1
	done
	return 1
}
for name in sleeper stubborn; do
	rm -rf -- "$TEST_RUNNER_STATE"
	mkdir -p "$TEST_RUNNER_STATE"
	SQUAD_KIT_TEST_TIMEOUT=2 GITHUB_ACTIONS=true run_suite 1 2 "$fixtures/$name.sh" "$fixtures/pass.sh"
	grep -qxF "done TIMEOUT $fixtures/$name.sh 2s" "$test_dir/out"
	grep -qxF "==== FAIL $fixtures/$name.sh（時間切れ: 2 秒で止めた）" "$test_dir/out"
	grep -qxF '直前に通ったケース: PASS fixture: before timeout' "$test_dir/out"
	grep -qF "::error file=$fixtures/$name.sh," "$test_dir/out"
	grep -qF "時間切れ%3A 2 秒で止めた" "$test_dir/out"
	grep -qxF "FAIL suite: 1 本が失敗: $fixtures/$name.sh" "$test_dir/out"
	grep -qxF 'PASS fixture: after failure' "$test_dir/out"
	# テストと、別のグループで起こした子の両方が、残っていない。
	pid_gone "$(cat "$TEST_RUNNER_STATE/test.pid")"
	pid_gone "$(cat "$TEST_RUNNER_STATE/child.pid")"
done
echo 'PASS runner: 上限を超えたファイルを、別のグループの子ごと止めて時間切れの失敗にし、ほかのファイルは流す'

# 行がないことを確認する。`! grep` は、bash の errexit の対象にならず、行があっても通ってしまう。
# grep の終了コードが 1（一致なし）のときだけ通し、一致（0）も、読めないファイルや不正な式（2 以上）も失敗にする。
no_line() {
	local found=0
	grep "$@" >/dev/null 2>&1 || found=$?
	[[ $found == 1 ]]
}
# 上の no_line が、行があるときに失敗する（見逃さない）ことを、行のあるファイルで確認する。
# errexit が効くよう、別の bash で流す。`! grep` の形は最後まで進み、no_line は途中で止まる。
printf '123 1 1 S 0:01 sleep\n' >"$test_dir/sample-list"
[[ $(bash -c 'set -e; ! grep -q "^123 " "$1"; echo reached' _ "$test_dir/sample-list") == reached ]]
[[ -z $(bash -c "$(declare -f no_line); set -e; no_line -qE '^123 ' \"\$1\"; echo reached" _ "$test_dir/sample-list" || :) ]]
if no_line -qE '^123 ' "$test_dir/sample-list"; then
	echo 'no_line が、行のあるファイルで通った' >&2
	exit 1
fi
no_line -qE '^124 ' "$test_dir/sample-list"
if no_line -qE '^124 ' "$test_dir/missing-file"; then
	echo 'no_line が、読めないファイルで通った' >&2
	exit 1
fi

# 時間切れの記録。tty-session.py の下で眠るファイルを短い上限で止め、止める前のプロセスの一覧と、
# 登録したプロセスのスタック（select で待つ行）がログに出ることを確認する。
cat >"$fixtures/stacker.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
echo 'PASS fixture: before timeout'
# セッションの外のプロセスの PID と、整数でない名前のファイルを置く。どちらへも SIGUSR2 は送られない。
touch "$SQUAD_KIT_TEST_STACK_DIR/$(cat "$TEST_RUNNER_STATE/outside.pid")" "$SQUAD_KIT_TEST_STACK_DIR/not-a-pid"
printf '%s\n' "$$" >"$TEST_RUNNER_STATE/test.pid"
python3 -I "$TEST_RUNNER_KIT/tests/tty-session.py" --output "$TMPDIR/out" --error "$TMPDIR/err" -- sleep 60
FIXTURE
rm -rf -- "$TEST_RUNNER_STATE"
mkdir -p "$TEST_RUNNER_STATE"
python3 -c 'import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])' sleep 60 &
outside=$!
printf '%s\n' "$outside" >"$TEST_RUNNER_STATE/outside.pid"
SQUAD_KIT_TEST_TIMEOUT=2 run_suite 1 1 "$fixtures/stacker.sh"
grep -qxF "==== FAIL $fixtures/stacker.sh（時間切れ: 2 秒で止めた）" "$test_dir/out"
grep -qxF -- '---- 時間切れの記録（2 秒）' "$test_dir/out"
grep -qxF 'プロセスの一覧（PID 親 グループ 状態 経過 コマンド）' "$test_dir/out"
# 一覧は、PID・親・グループ・状態・経過時間・コマンドの順で、セッションの tty-session.py を含む。ゾンビの行は求めない。
grep -qE '^[0-9]+ [0-9]+ [0-9]+ [A-Z][A-Za-z+<>]* +[0-9:.-]+ .*tty-session\.py' "$test_dir/out"
# 一覧にセッションの外のプロセスはなく、外のプロセスは SIGUSR2 を受けていない。
# 外の PID の名前のファイルは、印がないので、送らなかった行に理由が出る。整数でない名前は何も出さない。
no_line -E "^$outside [0-9]+ [0-9]+ " "$test_dir/out"
grep -qxF "送らなかった $outside 印が合わない" "$test_dir/out"
grep -qE '^送った [0-9]+$' "$test_dir/out"
no_line -F 'not-a-pid' "$test_dir/out"
kill -0 "$outside"
kill "$outside"
wait "$outside" 2>/dev/null || :
# スタックは、セッションにいる親の run() が select で待つ行を指す。
# 包みは setsid で別のセッションへ移るので、ここには出ない。
run_select=$(grep -n 'select.select(\[master, status_r\]' "$root/tests/tty-session.py" | cut -d: -f1)
[[ $run_select =~ ^[0-9]+$ ]]
grep -qE "tty-session\.py\", line $run_select in run\$" "$test_dir/out"
pid_gone "$(cat "$TEST_RUNNER_STATE/test.pid")"
echo 'PASS runner: 時間切れにプロセスの一覧と tty-session の select のスタックを出し、整数でない名前と外の PID へは送らない'

# 送る相手を選ぶ STACKS。セッションの中と外に、登録した 1 つと、印や情報が合わない様々なプロセスを置き、
# 送るのは登録を終えて印と OS の情報が合った 1 つだけで、ほかは理由つきで送らないことを確認する。
# 送られたら default の動作で終わるプロセスを置き、送られていないことは、終了の状態が 0 のままであることで確認する。
cat >"$test_dir/stacks-case.py" <<'PY'
import faulthandler
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile

stop = sys.argv[1]
directory = tempfile.mkdtemp()
hold_r, hold_w = os.pipe()
report_r, report_w = os.pipe()
info_r, info_w = os.pipe()
result_r, result_w = os.pipe()


def read_exact(descriptor, count):
    data = b''
    while len(data) < count:
        data += os.read(descriptor, count - len(data))
    return data


def member(register):
    """生成した位置のセッションに残り、親が hold_w を閉じるまで止まる。register なら、自分で登録する。"""
    pid = os.fork()
    if pid == 0:
        if hold_w is not None:
            os.close(hold_w)
        if register:
            temporary = os.path.join(directory, f'registering-{os.getpid()}')
            opened = open(temporary, 'wb')
            opened.write(f'{os.getpid()} {os.getppid()} {os.getpgrp()} {os.getsid(0)}\n'.encode())
            opened.flush()
            faulthandler.register(signal.SIGUSR2, file=opened, all_threads=True)
            os.rename(temporary, os.path.join(directory, str(os.getpid())))
        os.write(report_w, b'.')
        os.read(hold_r, 1)
        os._exit(0)
    return pid


kinds = ['good', 'ppid', 'smark', 'pmark', 'empty', 'link', 'fifo']
leader = os.fork()
if leader == 0:
    os.setsid()
    os.close(hold_w)
    hold_w = None
    pids = {kind: member(kind == 'good') for kind in kinds}
    read_exact(report_r, len(kinds))
    os.write(info_w, json.dumps(pids).encode())
    os.read(hold_r, 1)
    os.write(result_w, json.dumps({kind: os.waitpid(pid, 0)[1] for kind, pid in pids.items()}).encode())
    os._exit(0)
pids = json.loads(os.read(info_r, 65536))
outside = {kind: member(False) for kind in ('claim', 'own')}
read_exact(report_r, len(outside))
dead = os.fork()
if dead == 0:
    os._exit(0)
os.waitpid(dead, 0)
session, group = leader, os.getpgrp()


def put(name, text):
    with open(os.path.join(directory, str(name)), 'w') as stream:
        stream.write(text)


put(pids['ppid'], f'{pids["ppid"]} 1 {session} {session}\n')
put(pids['smark'], f'{pids["smark"]} {session} {session} {session + 1}\n')
put(pids['pmark'], f'{pids["pmark"] + 1} {session} {session} {session}\n')
put(pids['empty'], '')
put('real-mark', f'{pids["link"]} {session} {session} {session}\n')
os.symlink(os.path.join(directory, 'real-mark'), os.path.join(directory, str(pids['link'])))
os.mkfifo(os.path.join(directory, str(pids['fifo'])))
put(outside['claim'], f'{outside["claim"]} {os.getpid()} {group} {session}\n')
put(outside['own'], f'{outside["own"]} {os.getpid()} {group} {os.getsid(0)}\n')
put(dead, f'{dead} {os.getpid()} {group} {session}\n')
for name in ('not-a-pid', 'registering-123', '0', '-5'):
    put(name, '')


def stacks(path, where):
    return subprocess.run([sys.executable, '-I', path, str(session), 'STACKS', where],
                          capture_output=True, text=True, timeout=60)


outcome = stacks(stop, directory)
expected = sorted([
    f'送った {pids["good"]}',
    f'送らなかった {pids["ppid"]} プロセスが合わない',
    f'送らなかった {pids["smark"]} 印が合わない',
    f'送らなかった {pids["pmark"]} 印が合わない',
    f'送らなかった {pids["empty"]} 印が合わない',
    f'送らなかった {pids["link"]} 印が合わない',
    f'送らなかった {pids["fifo"]} 印が合わない',
    f'送らなかった {outside["claim"]} プロセスが合わない',
    f'送らなかった {outside["own"]} 印が合わない',
    f'送らなかった {dead} プロセスが合わない',
])
try:
    assert sorted(outcome.stdout.splitlines()) == expected, (outcome.stdout, expected)
    assert outcome.returncode == 0, outcome
finally:
    os.close(hold_w)
    results = json.loads(os.read(result_r, 65536) or b'{}')
    statuses = {kind: os.waitpid(pid, 0)[1] for kind, pid in outside.items()}
    os.waitpid(leader, 0)
# 送られたのは登録した 1 つだけで、ほかのプロセスは SIGUSR2 を受けずに 0 で終わる。
assert set(results) == set(kinds) and all(status == 0 for status in results.values()), results
assert all(status == 0 for status in statuses.values()), statuses
with open(os.path.join(directory, str(pids['good']))) as stream:
    lines = stream.read().splitlines()
assert lines[0] == f'{pids["good"]} {leader} {leader} {leader}' and any('File "' in line for line in lines[1:]), lines
# 送れた PID が 0 のときは、何も出さず 1 で終わる。
empty = tempfile.mkdtemp()
nothing = stacks(stop, empty)
assert (nothing.returncode, nothing.stdout) == (1, ''), nothing
shutil.rmtree(directory)
shutil.rmtree(empty)
PY
python3 -I "$test_dir/stacks-case.py" "$kit/tests/stop-session.py"
# 選ぶ確認を外した原本のコピーでは、同じケースが失敗する（ケースが見逃さない）。
n=0
for fault in 's/if actual != mark:/if False:/' 's/mark is None or mark\[0\] != pid or mark\[3\] != session/mark is None/' 's/ | os.O_NOFOLLOW//'; do
	n=$((n + 1))
	sed "$fault" "$kit/tests/stop-session.py" >"$test_dir/stop-session-broken-$n.py"
	if cmp -s "$kit/tests/stop-session.py" "$test_dir/stop-session-broken-$n.py"; then
		echo "壊したコピー $n が、原本と同じ" >&2
		exit 1
	fi
	if python3 -I "$test_dir/stacks-case.py" "$test_dir/stop-session-broken-$n.py" >/dev/null 2>&1; then
		echo "壊したコピー $n でも、STACKS のケースが通った" >&2
		exit 1
	fi
done
echo 'PASS runner: STACKS は登録した同じプロセスにだけ送り、印や OS の情報が合わないものと整数でない名前には送らず、壊したコピーでは失敗する'

# 登録（tests/tty-session.py の register_stack）は、印を書いてから登録し、成功したときだけ PID の名前で公開する。
cat >"$test_dir/registration-case.py" <<'PY'
import faulthandler
import importlib.util
import os
import signal
import sys
import tempfile

helper = sys.argv[1]


def load():
    spec = importlib.util.spec_from_file_location('tty_session', helper)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# 変数がないとき、変数の場所がないとき、公開の改名が失敗したときは、何も公開せず、一時のファイルも残さず、登録も残さない。
os.environ.pop('SQUAD_KIT_TEST_STACK_DIR', None)
load().register_stack()
assert not faulthandler.unregister(signal.SIGUSR2)
missing = os.path.join(tempfile.mkdtemp(), 'no-such-directory')
os.environ['SQUAD_KIT_TEST_STACK_DIR'] = missing
load().register_stack()
assert not os.path.exists(missing) and not faulthandler.unregister(signal.SIGUSR2)
failing = tempfile.mkdtemp()
os.environ['SQUAD_KIT_TEST_STACK_DIR'] = failing
broken = load()
original_rename = os.rename


def refuse(*_):
    raise OSError('injected rename failure')


os.rename = refuse
try:
    broken.register_stack()
finally:
    os.rename = original_rename
assert os.listdir(failing) == [] and not faulthandler.unregister(signal.SIGUSR2), os.listdir(failing)
# 登録に失敗しても、run() の動作は変わらない。
output, error = os.path.join(failing, 'out'), os.path.join(failing, 'err')
os.environ['SQUAD_KIT_TEST_STACK_DIR'] = missing
assert load().run(['true'], output=output, error=error) == 0
# 成功したときは、PID の名前のファイルだけが残り、先頭に印があり、SIGUSR2 でスタックが続く。
good = tempfile.mkdtemp()
os.environ['SQUAD_KIT_TEST_STACK_DIR'] = good
load().register_stack()
assert os.listdir(good) == [str(os.getpid())], os.listdir(good)
os.kill(os.getpid(), signal.SIGUSR2)
with open(os.path.join(good, str(os.getpid()))) as stream:
    lines = stream.read().splitlines()
assert lines[0] == f'{os.getpid()} {os.getppid()} {os.getpgrp()} {os.getsid(0)}' and any('File "' in line for line in lines[1:]), lines
PY
python3 -I "$test_dir/registration-case.py" "$kit/tests/tty-session.py"
echo 'PASS runner: 登録は印を書いてから登録し、成功したときだけ PID の名前で公開して、失敗しても動作を変えない'

# 1 つも送れなくても、記録は進み、テストは今までどおり止まる。登録しないテストの PID の名前のファイルは、印がないので送らない。
cat >"$fixtures/unregistered.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
trap 'touch "$TEST_RUNNER_STATE/got-usr2"' USR2
touch "$SQUAD_KIT_TEST_STACK_DIR/$$"
printf '%s\n' "$$" >"$TEST_RUNNER_STATE/test.pid"
sleep 60 &
wait $!
FIXTURE
rm -rf -- "$TEST_RUNNER_STATE"
mkdir -p "$TEST_RUNNER_STATE"
SQUAD_KIT_TEST_TIMEOUT=2 run_suite 1 1 "$fixtures/unregistered.sh"
grep -qxF "==== FAIL $fixtures/unregistered.sh（時間切れ: 2 秒で止めた）" "$test_dir/out"
grep -qxF "送らなかった $(cat "$TEST_RUNNER_STATE/test.pid") 印が合わない" "$test_dir/out"
no_line -E '^送った ' "$test_dir/out"
no_line -F 'のスタック' "$test_dir/out"
[[ ! -e $TEST_RUNNER_STATE/got-usr2 ]]
pid_gone "$(cat "$TEST_RUNNER_STATE/test.pid")"
echo 'PASS runner: 1 つも送れなくても、記録を終えて、テストを止める'

# 終わったのに回収されていない子（ゾンビ）がいるセッションでも、LIST はほかのプロセスを出して 0 で終わる。
# macOS ではゾンビの os.getsid() が失敗するので、ゾンビの行は求めない。出るなら、状態は Z になる。
python3 -I - "$kit/tests/stop-session.py" <<'PY'
import os
import signal
import subprocess
import sys

read_fd, write_fd = os.pipe()
leader = os.fork()
if leader == 0:
    os.close(read_fd)
    os.setsid()
    child = os.fork()
    if child == 0:
        os._exit(0)
    # 子の終了を待つが、回収はしない。子はゾンビのまま残る。
    os.waitid(os.P_PID, child, os.WEXITED | os.WNOWAIT)
    os.write(write_fd, str(child).encode())
    os.close(write_fd)
    signal.pause()
    os._exit(0)
os.close(write_fd)


def listing_of(session):
    return subprocess.run([sys.executable, '-I', sys.argv[1], str(session), 'LIST'],
                          capture_output=True, text=True)


try:
    zombie = int(os.read(read_fd, 100))
    listing = listing_of(leader)
    assert listing.returncode == 0, listing
    rows = {int(row.split()[0]): row.split(maxsplit=5) for row in listing.stdout.splitlines()}
    assert leader in rows, rows
    assert all(len(row) == 6 for row in rows.values()), rows
    assert os.getpid() not in rows, rows
    assert all(row[3].startswith('Z') for pid, row in rows.items() if pid == zombie), rows
    assert set(rows) <= {leader, zombie}, rows
finally:
    os.close(read_fd)
    os.kill(leader, signal.SIGKILL)
    os.waitpid(leader, 0)
# セッションにプロセスがなければ、何も出さずに 1 で終わる。
empty = listing_of(leader)
assert empty.returncode == 1 and not empty.stdout, empty
PY
echo 'PASS runner: ゾンビのいるセッションでも LIST は、ほかのプロセスを出して 0 で終わり、プロセスがなければ 1 で終わる'

# 既定の上限は、時計だけを進めて確認し、実際には 450 秒待たない。
mkdir -p "$test_dir/clock"
cat >"$test_dir/clock/date" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ $* == +%s ]]
clock="$TEST_RUNNER_STATE/clock.$PPID"
if [[ ! -f $clock ]]; then
	echo 0 >"$clock"
	echo 0
	exit 0
fi
# テストとその子が起きてから時計を進め、起動前の時間切れを避ける。
for ((attempt=0; attempt<200; attempt++)); do
	[[ -s $TEST_RUNNER_STATE/child.pid && -s $TEST_RUNNER_STATE/test.pid ]] && break
	sleep 0.1
done
[[ -s $TEST_RUNNER_STATE/child.pid && -s $TEST_RUNNER_STATE/test.pid ]]
read -r seconds <"$clock"
seconds=$((seconds + 450))
printf '%s\n' "$seconds" | tee "$clock"
STUB
chmod +x "$test_dir/clock/date"
(
	# このテスト自身を流す外側のランナーから渡された上限も外す。
	unset SQUAD_KIT_TEST_TIMEOUT
	export PATH="$test_dir/clock:$PATH"
	rm -rf -- "$TEST_RUNNER_STATE"
	mkdir -p "$TEST_RUNNER_STATE"
	GITHUB_ACTIONS=true run_suite 1 1 "$fixtures/sleeper.sh"
	grep -qxF "done TIMEOUT $fixtures/sleeper.sh 450s" "$test_dir/out"
	grep -qxF "==== FAIL $fixtures/sleeper.sh（時間切れ: 450 秒で止めた）" "$test_dir/out"
	grep -qF "::error file=$fixtures/sleeper.sh," "$test_dir/out"
	grep -qF '時間切れ%3A 450 秒で止めた' "$test_dir/out"
	grep -qxF "FAIL suite: 1 本が失敗: $fixtures/sleeper.sh" "$test_dir/out"
	pid_gone "$(cat "$TEST_RUNNER_STATE/test.pid")"
	pid_gone "$(cat "$TEST_RUNNER_STATE/child.pid")"
	# run-one.sh を直接呼んだときの既定も、同じ値である。
	rm -rf -- "$TEST_RUNNER_STATE"
	mkdir -p "$TEST_RUNNER_STATE" "$test_dir/direct/0/home" "$test_dir/direct/0/tmp"
	bash "$kit/tests/run-one.sh" "$kit" "$test_dir/direct" 0 "$fixtures/sleeper.sh" >"$test_dir/out" 2>"$test_dir/err"
	grep -qxF "done TIMEOUT $fixtures/sleeper.sh 450s" "$test_dir/out"
	read -r status elapsed limit <"$test_dir/direct/0/result"
	[[ $status == 124 && $limit == 450 ]]
	pid_gone "$(cat "$TEST_RUNNER_STATE/test.pid")"
	pid_gone "$(cat "$TEST_RUNNER_STATE/child.pid")"
)
echo 'PASS runner: 上限の指定がなければ run.sh と run-one.sh は 450 秒で止め、見出し・進み具合・注釈に出す'

# 上限の中で終わるファイルは、上限を設ける前と同じ結果と出力になる。
SQUAD_KIT_TEST_TIMEOUT=2 run_suite 0 1 "$fixtures/pass.sh"
grep -qE "^done PASS $fixtures/pass.sh [0-9]+s$" "$test_dir/out"
grep -qE "^==== PASS $fixtures/pass.sh（[0-9]+ 秒）$" "$test_dir/out"
! grep -qF '時間切れ' "$test_dir/out"
grep -qxF 'PASS suite: すべてのテスト（1 本、並列 1）' "$test_dir/out"
echo 'PASS runner: 上限の中で終わるファイルは、時間切れの表示なしで今までと同じ結果になる'

for invalid in '' 0 -1 invalid 1.5; do
	SQUAD_KIT_TEST_TIMEOUT="$invalid" run_suite 2 1 "$fixtures/pass.sh"
	grep -qF 'SQUAD_KIT_TEST_TIMEOUT は正の整数（秒）にしてください' "$test_dir/err"
	[[ ! -s $test_dir/out ]]
done
echo 'PASS runner: 上限が正の整数でなければテストを流さず 2 で終わる'

# 割り込まれたときも、別のセッションで動いているテストとその子を残さない。
rm -rf -- "$TEST_RUNNER_STATE"
mkdir -p "$TEST_RUNNER_STATE"
SQUAD_KIT_TEST_JOBS=1 bash "$kit/tests/run.sh" "$fixtures/sleeper.sh" >"$test_dir/out" 2>"$test_dir/err" &
suite_pid=$!
for ((attempt=0; attempt<200; attempt++)); do
	[[ -s $TEST_RUNNER_STATE/child.pid && -s $TEST_RUNNER_STATE/test.pid ]] && break
	sleep 0.1
done
[[ -s $TEST_RUNNER_STATE/child.pid && -s $TEST_RUNNER_STATE/test.pid ]]
kill -TERM "$suite_pid"
result=0
wait "$suite_pid" || result=$?
[[ $result == 143 ]]
pid_gone "$(cat "$TEST_RUNNER_STATE/test.pid")"
pid_gone "$(cat "$TEST_RUNNER_STATE/child.pid")"
[[ -z $(find "$kit/tmp" -name 'test-run.*' -type d -print 2>/dev/null) ]]
echo 'PASS runner: 割り込まれたら、動いているテストとその子もセッションごと止めて終わる'

# 起動の直後、セッションの ID を登録する前に割り込まれても、テストを残さない。
# run-one.sh の test_pid=$! の直前に止める補助を BASH_ENV で入れ、止まっている間に run.sh へ TERM を送る。
cat >"$fixtures/startup.sh" <<'FIXTURE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$$" >"$TEST_RUNNER_STATE/startup.pid"
sleep 60
FIXTURE
cat >"$fixtures/stall-hook.sh" <<'HOOK'
_stall() {
	if [[ $BASH_COMMAND == 'test_pid=$!' && -n ${TEST_RUNNER_STATE-} ]]; then
		touch "$TEST_RUNNER_STATE/stalled"
		sleep 5
	fi
}
trap _stall DEBUG
HOOK
rm -rf -- "$TEST_RUNNER_STATE"
mkdir -p "$TEST_RUNNER_STATE"
BASH_ENV="$fixtures/stall-hook.sh" SQUAD_KIT_TEST_JOBS=1 bash "$kit/tests/run.sh" "$fixtures/startup.sh" >"$test_dir/out" 2>"$test_dir/err" &
suite_pid=$!
for ((attempt=0; attempt<200; attempt++)); do
	[[ -e $TEST_RUNNER_STATE/stalled ]] && break
	sleep 0.1
done
[[ -e $TEST_RUNNER_STATE/stalled ]]
# 子が起きて、登録を待たずに新しいセッションへ移る作りなら、テストが動き出す時間を置く。
sleep 1.5
kill -TERM "$suite_pid"
result=0
wait "$suite_pid" || result=$?
[[ $result == 143 ]]
# 登録の前に割り込まれたので、テストは起きない。起きていたら、割り込みのあとに残る。
sleep 1
[[ ! -e $TEST_RUNNER_STATE/startup.pid ]]
[[ -z $(find "$kit/tmp" -name 'test-run.*' -type d -print 2>/dev/null) ]]
echo 'PASS runner: セッションの ID を登録する前に割り込まれても、テストを起こさず、何も残さない'

rm "$kit/tests/project-test.sh"
run_suite 2 1 "$fixtures/pass.sh"
grep -qxF '重みの一覧にあるファイルがありません: tests/project-test.sh' "$test_dir/err"
[[ ! -s $test_dir/out ]]
printf ':\n' >"$kit/tests/project-test.sh"
echo 'PASS runner: 重みの一覧が古ければテストを流さず 2 で終わる'

# 標準エラーを err に向けた中で止まったときも、失敗の後始末が err へ書き足し続けず、元の標準エラーへ出して終わる。
mkdir -p "$fixtures/trap/tests"
{ sed -n "1,/^trap 'test_exit=/p" "$root/tests/webhooks-test.sh"; cat <<'FIXTURE'
printf 'out of case\n' >"$test_dir/out"
{ echo 'error of case' >&2; false; } 2>"$test_dir/err"
FIXTURE
} >"$fixtures/trap/tests/trap-test.sh"
result=0
perl -e 'alarm 20; exec @ARGV' bash "$fixtures/trap/tests/trap-test.sh" >"$test_dir/trap-out" 2>"$test_dir/trap-err" || result=$?
[[ $result == 1 ]]
grep -qxF 'out of case' "$test_dir/trap-err"
grep -qxF 'error of case' "$test_dir/trap-err"
[[ -z $(find "$fixtures/trap/tmp" -mindepth 1 -print) ]]
# 失敗の後始末で out と err を出すテストは、どれも控えた標準エラーへ出す。
for file in "$root"/tests/*.sh; do
	grep -q "^trap 'test_exit=" "$file" || continue
	[[ $(grep -B1 "^trap 'test_exit=" "$file" | head -n 1) == 'exec 8>&2' ]]
	! grep "^trap 'test_exit=" "$file" | grep -qF '>&2'
done
echo 'PASS runner: 標準エラーを err に向けた中で止まっても、失敗の後始末は元の標準エラーへ出して終わる'

# 重みと分け方。重みの一覧と流す順は、小さな原本のコピーで確認する。
rm -f "$kit"/tests/*-test.sh
printf '# 重み\ntests/a-test.sh 50\ntests/b-test.sh 40\ntests/c-test.sh 30\ntests/d-test.sh 20\n tests/e-test.sh   20 \n\n# 一覧にない f・g・h は 30 秒\n' >"$kit/tests/test-weights"
all_tests=(tests/a-test.sh tests/b-test.sh tests/c-test.sh tests/d-test.sh tests/e-test.sh tests/f-test.sh tests/g-test.sh tests/h-test.sh)
# 1 本ずつ流し、テストが起こされた順を記録する。
for name in a b c d e f g h; do
	printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >>"$TEST_RUNNER_ORDER"\necho "PASS fixture: %s"\n' "$name" "$name" >"$kit/tests/$name-test.sh"
done
export TEST_RUNNER_ORDER="$test_dir/order"
shard_suite() {
	local expected=$1 shard=$2 result=0
	shift 2
	: >"$TEST_RUNNER_ORDER"
	SQUAD_KIT_TEST_SHARD="$shard" SQUAD_KIT_TEST_JOBS=1 bash "$kit/tests/run.sh" "$@" >"$test_dir/out" 2>"$test_dir/err" || result=$?
	[[ $result == "$expected" ]]
}
# 重みの大きい順、同じ重みは名前の順に、1 本ずつ起こす。f・g・h は 30 秒の扱い。
SQUAD_KIT_TEST_JOBS=1 bash "$kit/tests/run.sh" >"$test_dir/out" 2>"$test_dir/err"
[[ $(tr '\n' ' ' <"$TEST_RUNNER_ORDER") == 'a b c f g h d e ' ]]
grep -qxF 'PASS suite: すべてのテスト（8 本、並列 1）' "$test_dir/out"
echo 'PASS runner: 重みの大きい順、同じ重みは名前の順に起こし、一覧にないファイルは 30 秒として扱う'

# どのシャードの分け方でも、各ファイルがちょうど 1 つのシャードに入り、合わせると選んだ全部になる。
for count in 1 2 3 4 5 6; do
	: >"$test_dir/union"
	for ((index=1; index<=count; index++)); do
		shard_suite 0 "$index/$count"
		ran=$(wc -l <"$TEST_RUNNER_ORDER" | tr -d ' ')
		grep -qxF "PASS suite: すべてのテスト（${ran} 本、並列 1、シャード ${index}/${count}）" "$test_dir/out"
		cat "$TEST_RUNNER_ORDER" >>"$test_dir/union"
		# シャードの中の起こす順も、重みの大きい順。
		shard_order=$(tr '\n' ' ' <"$TEST_RUNNER_ORDER")
		expected_order=$(for name in a b c f g h d e; do grep -qx "$name" "$TEST_RUNNER_ORDER" && printf '%s ' "$name"; done; true)
		[[ $shard_order == "$expected_order" ]]
	done
	[[ $(sort "$test_dir/union" | tr '\n' ' ') == 'a b c d e f g h ' ]]
done
echo 'PASS runner: N を 1〜6 にしたとき、各シャードのファイルが重ならず、合わせると選んだ全部になる'

# 分け方は重みの合計がいちばん小さいシャードへ入れる決まりで、同じ合計なら番号の小さいほうへ入れる。
shard_suite 0 1/3 "${all_tests[@]}"
[[ $(tr '\n' ' ' <"$TEST_RUNNER_ORDER") == 'a h ' ]]
shard_suite 0 2/3 "${all_tests[@]}"
[[ $(tr '\n' ' ' <"$TEST_RUNNER_ORDER") == 'b g e ' ]]
shard_suite 0 3/3 "${all_tests[@]}"
[[ $(tr '\n' ' ' <"$TEST_RUNNER_ORDER") == 'c f d ' ]]
echo 'PASS runner: 重みの大きい順に、合計がいちばん小さい（同じなら番号の小さい）シャードへ入れる'

# 引数でファイルを選んだときは、選んだファイルを分ける。
shard_suite 0 2/2 tests/c-test.sh tests/a-test.sh tests/b-test.sh
[[ $(tr '\n' ' ' <"$TEST_RUNNER_ORDER") == 'b c ' ]]
shard_suite 0 1/2 tests/c-test.sh tests/a-test.sh tests/b-test.sh
[[ $(tr '\n' ' ' <"$TEST_RUNNER_ORDER") == 'a ' ]]
echo 'PASS runner: 引数でファイルを選んだときは、選んだファイルを分ける'

# 流すファイルがないシャードは、0 本と書いて 0 で終わる。
shard_suite 0 3/3 tests/a-test.sh
[[ ! -s $TEST_RUNNER_ORDER ]]
grep -qxF 'PASS suite: すべてのテスト（0 本、並列 1、シャード 3/3）' "$test_dir/out"
echo 'PASS runner: 流すファイルがないシャードは 0 本と書いて 0 で終わる'

# 指定が正しくなければ、テストを流さず 2 で終わる。
for invalid in '' 0 0/2 3/2 1/0 1 2/ /2 a/b 1/2/3 -1/2 1.5/2 ' 1/2' '1/2 ' 1234567/1234568; do
	shard_suite 2 "$invalid"
	grep -qF 'SQUAD_KIT_TEST_SHARD は k/N の形' "$test_dir/err"
	[[ ! -s $test_dir/out && ! -s $TEST_RUNNER_ORDER ]]
done
echo 'PASS runner: シャードの指定が k/N（1 ≦ k ≦ N の正の整数）でなければテストを流さず 2 で終わる'

# 重みの一覧の誤りは、テストを流さず 2 で終わる。
for bad in 'tests/a-test.sh' 'tests/a-test.sh abc' 'tests/a-test.sh -5' 'tests/a-test.sh 1.5' 'tests/a-test.sh 1 2' 'tests/a-test.sh 1234567890' $'tests/a-test.sh 5\ntests/a-test.sh 6'; do
	printf '%b\n' "$bad" >"$kit/tests/test-weights"
	run_suite 2 1 tests/a-test.sh
	grep -qE '重みの一覧(の行が正しくありません|に同じファイルが 2 回あります)' "$test_dir/err"
	[[ ! -s $test_dir/out ]]
done
rm "$kit/tests/test-weights"
run_suite 2 1 tests/a-test.sh
grep -qxF '重みの一覧がありません: tests/test-weights' "$test_dir/err"
echo 'PASS runner: 重みの一覧がないか書き方が正しくなければ、テストを流さず 2 で終わる'

# 本物の重みの一覧は、すべてのテストに重みがあり、存在しないファイルがない。
weighted=$(grep -vE '^[[:space:]]*(#|$)' "$root/tests/test-weights" | awk '{print $1}' | LC_ALL=C sort)
[[ -z $(printf '%s\n' "$weighted" | uniq -d) ]]
actual=$(cd "$root" && ls tests/*-test.sh | LC_ALL=C sort)
if [[ $weighted != "$actual" ]]; then
	diff <(printf '%s\n' "$weighted") <(printf '%s\n' "$actual") >&2 || :
	echo 'tests/test-weights が tests/*-test.sh と一致しません（重みのないファイルは追記し、なくなったファイルは消す）' >&2
	false
fi
while read -r name seconds extra; do
	case $name in ''|'#'*) continue ;; esac
	[[ -f $root/$name && -z $extra && $seconds =~ ^[0-9]+$ ]]
done <"$root/tests/test-weights"
echo 'PASS runner: 重みの一覧の名前が tests/*-test.sh と一致し、重複や存在しないファイルがない'
