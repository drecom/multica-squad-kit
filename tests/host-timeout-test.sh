#!/usr/bin/env bash
# この部分は、古い Codex と時間切れ・停止を確認できないとき・プロジェクトごとの許可ファイルを確認する。
set -euo pipefail
source "$(dirname "$0")/host-test-lib.sh"
# 前の部分が作る導入済みのホストと同居環境の状態を用意する。
set_mode stopped
run
# 同居する既存システムの Mac の代わり。マークのないファイルと資格情報を残す。
sed '/^# multica-squad-kit-managed$/d' "$root/common/guard/gh" >"$TEMPLATE_AGENT_HOME/bin/gh"
sed '/^# multica-squad-kit-managed$/d' "$root/common/guard/pre-push" >"$TEMPLATE_AGENT_HOME/git-hooks/pre-push"
printf '# existing codex config\nallow_login_shell = false\n' >"$TEMPLATE_AGENT_HOME/codex/config.toml"
printf 'original allowed repository\n' >"$TEMPLATE_AGENT_HOME/allowed-repos"
printf 'existing credential\n' >"$TEMPLATE_AGENT_HOME/claude/credentials.json"
printf 'existing codex credential\n' >"$TEMPLATE_AGENT_HOME/codex/auth.json"
mkdir "$test_dir/original"
for file in bin/gh git-hooks/pre-push codex/config.toml allowed-repos claude/credentials.json codex/auth.json; do
 mkdir -p "$test_dir/original/$(dirname "$file")"
 cp "$TEMPLATE_AGENT_HOME/$file" "$test_dir/original/$file"
done
set_mode running
agent_env
for spec in 'guard/gh:bin/gh' 'guard/pre-push:git-hooks/pre-push' 'codex/config.toml:codex/config.toml'; do
 target=${spec#*:}
 printf '# multica-squad-kit-managed\nold\n' >"$TEMPLATE_AGENT_HOME/$target"
done
run

echo old >"$test_dir/codex-strict"
set_mode running
agent_env
run
grep -qF '警告: この Codex は --strict-config を受け付けないため、設定を検証できませんでした' "$test_dir/err"
grep -q '^daemon status' "$test_dir/calls"
# 時間切れの扱い。docs/agent-settings.md の「時間切れの扱い」の表と同じ行を、実際のプロセスで、次の表から流す。
# 列: 名前|子孫の終了処理の印。上限 1 秒、猶予 3 秒で流し、どの行も猶予をすべて待ってから KILL を送る。
# term-<親>-<子孫>: 親は TERM で終わる（exit）か無視する（ignore）。子孫は、なし（none）、終了処理をする（finish）、無視する（ignore）。
# term-exit-none は、親だけがゾンビのグループになる。zombie-desc は、子孫がゾンビのまま親が動き続け、KILL のあとに親だけがゾンビになる。
timeout_rows='term-exit-none|-
term-exit-finish|あり
term-exit-ignore|-
term-ignore-none|-
term-ignore-finish|あり
term-ignore-ignore|-
zombie-desc|-'
# 生存は ps の状態で読む。kill -0 は、ゾンビを生きたプロセスと同じに返すので使わない。本物の ps を使う。
proc_state() {
 local state
 state=$(/bin/ps -o stat= -p "$1" 2>/dev/null) || state=
 state=${state//[[:space:]]/}
 case $state in
 '') echo gone ;;
 Z*) echo zombie ;;
 *) echo running ;;
 esac
}
# PID が数値でなければ失敗にする。空の PID を「いない」と読んで通さない。
is_pid() { [[ $1 =~ ^[0-9]+$ ]]; }
not_running() { is_pid "$1" && [[ $(proc_state "$1") != running ]]; }
is_gone() { is_pid "$1" && [[ $(proc_state "$1") == gone ]]; }
# 判定が、生きたプロセス・ゾンビ・回収済み・空の PID を分けることを先に確認する。
/bin/sleep 30 &
live=$!
[[ $(proc_state "$live") == running ]]
! not_running "$live"
! not_running ''
! is_gone ''
! not_running 'abc'
python3 -c 'import os, sys, time
pid = os.fork()
if pid == 0:
    os._exit(0)
print(pid, flush=True)
time.sleep(30)' >"$test_dir/zombie-pid" &
zombie_parent=$!
for _ in $(seq 1 100); do [[ -s $test_dir/zombie-pid ]] && break; /bin/sleep 0.1; done
zombie=$(cat "$test_dir/zombie-pid")
is_pid "$zombie"
[[ $(proc_state "$zombie") == zombie ]]
not_running "$zombie"
! is_gone "$zombie"
kill "$zombie_parent" "$live"
wait "$zombie_parent" "$live" 2>/dev/null || true
# 親が死ぬと、ゾンビはシステムが回収する。
for _ in $(seq 1 100); do [[ $(proc_state "$zombie") == gone ]] && break; /bin/sleep 0.1; done
is_gone "$zombie"
# 別のプロセスのグループにいる対照のプロセスは、どの行でも残る。
/bin/sleep 300 &
control=$!
while IFS='|' read -r row marker; do
 echo "$row" >"$test_dir/codex-strict"
 rm -f "$test_dir/desc-pid" "$test_dir/desc-done" "$test_dir/codex-pid"
 set_mode running
 agent_env
 started=$(python3 -c 'import time; print(int(time.time() * 1000))')
 TEST_CODEX_SECONDS=1 TEST_CODEX_GRACE=3 TEST_CODEX_CONFIRM=2 run
 elapsed=$(( $(python3 -c 'import time; print(int(time.time() * 1000))') - started ))
 grep -qF '警告: 設定の検証が 1 秒で終わらず、確認できませんでした' "$test_dir/err"
 grep -q '^daemon status' "$test_dir/calls"
 # 下限は待機 1 秒＋猶予 3 秒。上限は検証の許す 6 秒（待機 1＋猶予 3＋確認 2）に、準備全体の余裕 3 秒を足した 9 秒。
 [[ $elapsed -ge 3900 && $elapsed -le 9000 ]] || { echo "時間切れの行 $row: ${elapsed} ミリ秒（期待 3900〜9000）" >&2; exit 1; }
 # 直接の子は検証の処理が回収し、子孫は実行中で残らない。
 is_gone "$(cat "$test_dir/codex-pid")"
 if [[ $row == *-none ]]; then [[ ! -f $test_dir/desc-pid ]]; else not_running "$(cat "$test_dir/desc-pid")"; fi
 if [[ $marker == あり ]]; then [[ -f $test_dir/desc-done ]]; else [[ ! -f $test_dir/desc-done ]]; fi
 [[ $(proc_state "$control") == running ]]
 [[ $(/bin/ps -o pgid= -p "$control" | tr -d ' ') != "$(cat "$test_dir/codex-pid")" ]]
done <<<"$timeout_rows"
kill "$control"
wait "$control" 2>/dev/null || true
echo 'PASS host: 古い Codex と時間切れは警告して進み、実際のプロセスの 7 行（親の終了・無視と子孫のなし・終了処理・無視、子孫だけのゾンビ）で、猶予をすべて待ち、子孫の終了処理を最後まで残し、実行中のプロセスと別のグループの対照のプロセスの扱いが決めたとおりになる'
# ゾンビだけのグループを、本物のプロセスで作る。signal 0・TERM・KILL の結果は OS で違い、macOS では EPERM を確認し、Linux では観測した結果を出す。
# どの状態も、停止の判定は ps の状態の読み取り（lib/codex-check.py の Operations.state）で分け、シグナルの結果から決めない。
python3 -I - "$root/lib/codex-check.py" <<'PY'
import importlib.util
import os
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("codex_check", sys.argv[1])
check = importlib.util.module_from_spec(spec)
spec.loader.exec_module(check)


def stat(pid):
    done = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return done.stdout.decode().strip()


def wait_for(predicate):
    for _ in range(100):
        if predicate():
            return True
        time.sleep(0.1)
    return False


def send(pgid, number):
    try:
        os.killpg(pgid, number)
    except ProcessLookupError:
        return "ESRCH"
    except PermissionError:
        return "EPERM"
    return "ok"


def start(script):
    return subprocess.Popen(["/bin/bash", "-c", script], start_new_session=True)


def read_state(proc):
    return check.Operations(proc).state(proc.pid, 10)


# 親だけがゾンビのグループ（子孫はいない）。
parent = start("exit 0")
assert wait_for(lambda: stat(parent.pid).startswith("Z")), "親がゾンビにならない"
observed = [send(parent.pid, number) for number in (0, signal.SIGTERM, signal.SIGKILL)]
assert read_state(parent) == check.STOPPED, "ゾンビだけのグループは停止済み"
name = "macOS" if sys.platform == "darwin" else sys.platform
print("観測 %s: ゾンビだけのグループへの signal 0・TERM・KILL の結果は %s" % (name, "・".join(observed)))
if sys.platform == "darwin":
    assert observed == ["EPERM"] * 3, observed
else:
    print("観測 %s: 設計の前提（成功）と%s" % (name, "一致する" if observed == ["ok"] * 3 else "違う"))
# 直接の子を回収すると、グループは空になる。空のグループは ESRCH で、停止済みである。
assert parent.wait() == 0
assert [send(parent.pid, number) for number in (0, signal.SIGTERM, signal.SIGKILL)] == ["ESRCH"] * 3
assert read_state(parent) == check.STOPPED, "空のグループは停止済み"

# 親だけがゾンビで、子孫が動いているグループは、実行中である。
mixed = start("/bin/sleep 300 & exit 0")
assert wait_for(lambda: stat(mixed.pid).startswith("Z")), "親がゾンビにならない"
assert read_state(mixed) == check.RUNNING
assert send(mixed.pid, 0) == "ok", "動くプロセスがあれば、signal 0 は成功する"
send(mixed.pid, signal.SIGKILL)
mixed.wait()

# 子孫だけがゾンビで、親が動いているグループは、実行中である。親が終われば、停止済みになる。
descendant = subprocess.Popen([sys.executable, "-c", "import os, sys, time\n"
                               "pid = os.fork()\n"
                               "if pid == 0:\n"
                               "    os._exit(0)\n"
                               "print(pid, flush=True)\n"
                               "time.sleep(300)"], stdout=subprocess.PIPE, start_new_session=True)
zombie = int(descendant.stdout.readline())
assert wait_for(lambda: stat(zombie).startswith("Z")), "子孫がゾンビにならない"
assert read_state(descendant) == check.RUNNING
send(descendant.pid, signal.SIGKILL)
assert wait_for(lambda: stat(descendant.pid).startswith("Z"))
assert read_state(descendant) == check.STOPPED
descendant.wait()
descendant.stdout.close()
PY
echo 'PASS host: ゾンビだけのグループが ps の状態で停止済みと読まれ、親だけ・子孫だけがゾンビで動くプロセスが残るグループは実行中と読まれ、macOS では signal 0・TERM・KILL が EPERM になる'
# 停止を確認できないとき。ps を差し替えて、グループの状態を読めない場合と、実行中のプロセスが残る場合を作る。
# 固定の診断で止まり、設定の誤りや python3 の不足と別の文になる。止まっても、KILL は送って直接の子は回収している。
mkdir "$test_dir/ps-bin"
cat >"$test_dir/ps-bin/ps" <<'STUB'
#!/bin/bash
base=${0%/*}/..
case $(cat "$base/ps-mode") in
fail) exit 1 ;;
garbage) echo 'not a process table' ;;
running) printf '  PID  PGID STAT COMMAND\n  %s   %s S    codex app-server\n' "$(cat "$base/codex-pid")" "$(cat "$base/codex-pid")" ;;
esac
STUB
chmod +x "$test_dir/ps-bin/ps"
echo term-ignore-none >"$test_dir/codex-strict"
for ps_mode in fail garbage running; do
 echo "$ps_mode" >"$test_dir/ps-mode"
 rm -f "$test_dir/codex-pid"
 set_mode running
 agent_env
 started=$(python3 -c 'import time; print(int(time.time() * 1000))')
 PATH="$test_dir/ps-bin:$PATH" TEST_CODEX_SECONDS=1 TEST_CODEX_GRACE=2 TEST_CODEX_CONFIRM=2 deny
 elapsed=$(( $(python3 -c 'import time; print(int(time.time() * 1000))') - started ))
 [[ $elapsed -ge 4900 && $elapsed -le 9000 ]] || { echo "停止を確認できない行 $ps_mode: ${elapsed} ミリ秒（期待 4900〜9000）" >&2; exit 1; }
 grep -qF '検証のプロセスの停止を確認できませんでした' "$test_dir/err"
 grep -qF "グループ $(cat "$test_dir/codex-pid")" "$test_dir/err"
 grep -qF 'ps -A -o pid,pgid,stat,command' "$test_dir/err"
 ! grep -qF 'Codex の設定が厳しい検証を通りません' "$test_dir/err"
 ! grep -qF 'python3 を確認して' "$test_dir/err"
 [[ ! -s $test_dir/calls ]]
 is_gone "$(cat "$test_dir/codex-pid")"
done
echo ok >"$test_dir/codex-strict"
echo 'PASS host: 停止を確認できないとき、ps が失敗する・読めない・実行中が残る場合のどれでも、設定の誤りや python3 の不足と別の固定の診断で止まる'
# ID を受け取る関数を、実際の bash と zsh の起動ファイルで確認する。
cat >"$test_dir/project.sh" <<'RUN'
#!/bin/bash
set -euo pipefail
root=$1
source "${DRAW_UI:-$root/lib/ui.sh}"
source "$root/lib/host.sh"
die() { echo "$*" >&2; exit 1; }
shift
prepare_project_host "$@"
RUN
/bin/bash "$test_dir/project.sh" "$root" project-a example/one
/bin/bash "$test_dir/project.sh" "$root" project-b example/two
[[ $(cat "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a") == example/one ]]
[[ $(cat "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-b") == example/two ]]
for id in project-a project-b; do
 shell_dir="$TEMPLATE_AGENT_HOME/template/shell/$id"
 ! grep -q '{{' "$shell_dir/.zshenv"
 cmp "$shell_dir/.zshenv" "$shell_dir/env.sh"
 BASH_ENV="$shell_dir/env.sh" /bin/bash -c 'test "$SQUAD_KIT_ALLOWED_REPOS" = "$1"' -- "$TEMPLATE_AGENT_HOME/allowed-repos.d/$id"
 ZDOTDIR="$shell_dir" /bin/zsh -c 'test "$SQUAD_KIT_ALLOWED_REPOS" = "$1"' -- "$TEMPLATE_AGENT_HOME/allowed-repos.d/$id"
done
cmp "$TEMPLATE_AGENT_HOME/allowed-repos" "$test_dir/original/allowed-repos"
cp "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a" "$test_dir/previous-project"
/bin/bash "$test_dir/project.sh" "$root" project-b example/updated
cmp "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a" "$test_dir/previous-project"
if /bin/bash "$test_dir/project.sh" "$root" '../bad' example/no >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
echo 'PASS host: プロジェクトごとの許可ファイルが、引用符や空白のある保存先でも bash・zsh の子へ届く'

/bin/bash "$test_dir/project.sh" "$root" project-a example/one EXAMPLE/TWO example/one
printf 'example/one\nexample/two\n' >"$test_dir/selected"
cmp "$test_dir/selected" "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a"
[[ $(python3 -c 'import os,sys; print(oct(os.stat(sys.argv[1]).st_mode & 0o777)[2:])' "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a") == 600 ]]
before_inode=$(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a")
/bin/bash "$test_dir/project.sh" "$root" project-a example/one example/two
[[ $(python3 -c 'import os,sys; print(os.stat(sys.argv[1]).st_ino)' "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a") == "$before_inode" ]]
[[ $(cat "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-b") == example/updated ]]
cmp "$TEMPLATE_AGENT_HOME/allowed-repos" "$test_dir/original/allowed-repos"
echo 'PASS host: 選んだ全件を一行ずつ小文字で重複なく許し、同じ選択の再実行と別プロジェクト・共有ファイルを保つ'

# 起動ファイルと共有のガードは本体を使い、送信先の gh だけを PATH で差し替える。
cp "$root/tests/guard-backend.sh" "$test_dir/bin/gh"
chmod +x "$test_dir/bin/gh"
export HOST_GH_CALLS="$test_dir/gh-calls" PATH="$TEMPLATE_AGENT_HOME/bin:$PATH"
unset GH_HOST
: >"$HOST_GH_CALLS"
mkdir "$test_dir/repository"
git -C "$test_dir/repository" init -q
shell_dir="$TEMPLATE_AGENT_HOME/template/shell/project-a"
probe() (
 cd "$test_dir/repository"
 ZDOTDIR="$shell_dir" BASH_ENV="$shell_dir/env.sh" "$1" -c "$2" -- "$3" "$4" >"$test_dir/out" 2>"$test_dir/err"
)
for shell in /bin/bash /bin/zsh; do
 for repo in example/one example/two; do
  probe "$shell" 'gh pr comment 1 --repo "$1" --body probe' "$repo" ''
  probe "$shell" '"$1" origin "$2" </dev/null' "$TEMPLATE_AGENT_HOME/git-hooks/pre-push" "https://github.com/$repo"
 done
 before=$(wc -l <"$HOST_GH_CALLS")
 if probe "$shell" 'gh pr comment 1 --repo "$1" --body probe' example/updated ''; then exit 1; fi
 [[ $(wc -l <"$HOST_GH_CALLS") == "$before" ]]
 if probe "$shell" '"$1" origin "$2" </dev/null' "$TEMPLATE_AGENT_HOME/git-hooks/pre-push" https://github.com/example/updated; then exit 1; fi
done
[[ $(wc -l <"$HOST_GH_CALLS" | tr -d ' ') == 4 ]]
echo 'PASS host: bash・zsh の起動ファイルから両方の選択が gh と pre-push まで届き、別プロジェクトは送信前に拒否する'

/bin/bash "$test_dir/project.sh" "$root" project-a example/one >"$test_dir/out" 2>"$test_dir/err"
grep -qx '許すリポジトリから外しました: example/two' "$test_dir/err"
[[ $(cat "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a") == example/one ]]
for shell in /bin/bash /bin/zsh; do
 probe "$shell" 'gh pr comment 1 --repo "$1" --body probe' example/one ''
 before=$(wc -l <"$HOST_GH_CALLS")
 if probe "$shell" 'gh pr comment 1 --repo "$1" --body probe' example/two ''; then exit 1; fi
 [[ $(wc -l <"$HOST_GH_CALLS") == "$before" ]]
 if probe "$shell" '"$1" origin "$2" </dev/null' "$TEMPLATE_AGENT_HOME/git-hooks/pre-push" https://github.com/example/two; then exit 1; fi
done
/bin/bash "$test_dir/project.sh" "$root" project-a example/one >"$test_dir/out" 2>"$test_dir/err"
! grep -q '許すリポジトリから外しました' "$test_dir/err"
cmp "$TEMPLATE_AGENT_HOME/allowed-repos" "$test_dir/original/allowed-repos"
[[ $(cat "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-b") == example/updated ]]
echo 'PASS host: 外した全件を許可から消して表示し、既存の起動ファイルのまま次の gh・push で拒否する'

for invalid in '' 'bad/repo/path' $'example/two\nexample/three'; do
 if /bin/bash "$test_dir/project.sh" "$root" project-a example/one "$invalid" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
 [[ $(cat "$TEMPLATE_AGENT_HOME/allowed-repos.d/project-a") == example/one ]]
done
if /bin/bash "$test_dir/project.sh" "$root" project-new >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
[[ ! -e $TEMPLATE_AGENT_HOME/allowed-repos.d/project-new ]]
echo 'PASS host: 空の選択や後ろの不正な値で前の許可を壊さず、空の許可ファイルも作らない'

# 本物の gh が PATH の先でも、起動時と Claude の順の両方を確認する。
export TEST_GUARD_CALLS="$test_dir/guard-calls"
: >"$TEST_GUARD_CALLS"
PATH="$test_dir/bin:$TEMPLATE_AGENT_HOME/bin:$PATH" /bin/bash "$test_dir/project.sh" "$root" project-a example/one example/two >"$test_dir/out" 2>"$test_dir/err"
[[ $(grep -c '^許可の確認:' "$test_dir/err") == 2 ]]
[[ $(wc -l <"$TEST_GUARD_CALLS" | tr -d ' ') == 4 ]]
for repo in one two; do
 [[ $(grep -c "repos/example/$repo/git/refs" "$TEST_GUARD_CALLS") == 2 ]]
done
echo 'PASS host: 本物の gh が先でも起動時と Claude の順で確認し、許可の通信は各リポジトリ・シェルにつき 1 回に保つ'

for target in allowed-repos.d/project-a template/shell/project-a/.zshenv template/shell/project-a/env.sh; do
 cp "$TEMPLATE_AGENT_HOME/$target" "$test_dir/before-${target##*/}"
done
assert_previous_project() {
 for target in allowed-repos.d/project-a template/shell/project-a/.zshenv template/shell/project-a/env.sh; do
  cmp "$test_dir/before-${target##*/}" "$TEMPLATE_AGENT_HOME/$target"
 done
 [[ ! -e $TEMPLATE_AGENT_HOME/allowed-repos.d/project-new && ! -e $TEMPLATE_AGENT_HOME/template/shell/project-new ]]
 [[ ! -s $TEST_GUARD_CALLS ]]
 grep -q '従来の許可とシェル起動ファイルを保って停止' "$test_dir/err"
}
mkdir -p "$test_dir/package/lib" "$test_dir/package/common"
cp "$root/lib/host.sh" "$root/lib/ui.sh" "$root/lib/terminal.sh" "$root/lib/clock.sh" "$test_dir/package/lib/"
cp -R "$root/common/shell" "$test_dir/package/common/"
# .zshenv は起動時に直せても、env.sh がコマンド直前に戻さなければ止める。
head -n 2 "$root/common/shell/env.sh" >"$test_dir/package/common/shell/env.sh"
for id in project-a project-new; do
 : >"$TEST_GUARD_CALLS"
 if PATH="$test_dir/bin:$TEMPLATE_AGENT_HOME/bin:$PATH" /bin/bash "$test_dir/project.sh" "$test_dir/package" "$id" example/changed >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
 grep -q 'Claude の実行の順で gh がガードを選びません' "$test_dir/err"
 grep -q 'ひな形の env.sh' "$test_dir/err"
 assert_previous_project
done
echo 'PASS host: env.sh が PATH を戻さなければ Claude の順で通信前に止まり、既存の許可・起動ファイルを保ち新規にも書かない'

# ガード以外に gh がない PATH でも、ほかのホストの本物を探しに行かない。
mkdir "$test_dir/no-gh-bin"
for tool in tr cat; do ln -s "$(command -v "$tool")" "$test_dir/no-gh-bin/$tool"; done
for id in project-a project-new; do
 : >"$TEST_GUARD_CALLS"
 if PATH="$TEMPLATE_AGENT_HOME/bin:$test_dir/no-gh-bin" /bin/bash "$test_dir/project.sh" "$root" "$id" example/changed >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
 grep -q '本物の gh がガードの外の PATH に見つかりません' "$test_dir/err"
 assert_previous_project
done
echo 'PASS host: ガードの外に gh がなければ理由を出し、従来の許可・起動ファイルを保って止まる'
