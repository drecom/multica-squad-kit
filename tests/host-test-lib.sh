# tests/host-test.sh と tests/host-order-*-test.sh が共有する準備。スタブの gh・multica・claude・codex、prepare_host を流す run.sh、
# run・deny・set_mode・agent_env と、書かれるはずの Codex の設定を作る関数を置く。source して使う。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/host-test.XXXXXX")
# 標準エラーを err に向けたまま止まっても、trap が err 自身へ書き足し続けないよう、元の標準エラーを控えて出す。
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&8; fi; rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bin"
cp "$root/tests/guard-backend.sh" "$test_dir/bin/gh"
cat >"$test_dir/bin/multica" <<'STUB'
#!/bin/bash
set -euo pipefail
base=${0%/*}/..
mode=$(<"$base/mode")
printf '%s\n' "$*" >>"$base/calls"
if [[ -f $base/fail && $(<"$base/fail") == "$*" ]]; then echo 'intentional CLI failure' >&2; exit 77; fi
case "$*" in
'user profile get --output json') echo '{"id":"member-a"}' ;;
'daemon status --output json')
 case $mode in
 stopped|desktop) echo '{"status":"stopped","pid":null}' ;;
 busy) echo '{"status":"running","pid":4242,"daemon_id":"daemon-a","running_task_count":3,"active_task_count":3,"server_url":"https://example.test"}' ;;
 unknown) echo '{"status":"running","pid":4242,"daemon_id":"daemon-a"}' ;;
 *) echo '{"status":"running","pid":4242,"daemon_id":"daemon-a","running_task_count":0,"active_task_count":0,"server_url":"https://example.test"}' ;;
 esac ;;
'runtime list --output json')
 if [[ $mode == stopped || -f $base/no-runtimes ]]; then echo '[]'; elif [[ -n ${TEST_RUNTIME_LIST:-} ]]; then cat "$TEST_RUNTIME_LIST"; else
  echo '[{"id":"runtime-claude","owner_id":"member-a","daemon_id":"daemon-a","provider":"claude","status":"online"},{"id":"runtime-codex","owner_id":"member-a","daemon_id":"daemon-a","provider":"codex","status":"online"},{"id":"foreign","owner_id":"member-b","daemon_id":"daemon-a","provider":"claude","status":"online"},{"id":"other-host","owner_id":"member-a","daemon_id":"daemon-b","provider":"codex","status":"online"}]'
 fi ;;
'daemon stop') echo stopped >"$base/mode" ;;
'daemon start')
 [[ -z ${VSCODE_TEST_MARKER:-} && -z ${MULTICA_WORKSPACE_ID:-} && $SHELL == /bin/zsh ]] || exit 78
 printf 'CODEX_HOME=%s PATH=%s\n' "$CODEX_HOME" "$PATH" >"$base/process-env"
 printf '%s\n' "$MULTICA_SERVER_URL" >"$base/started-server"
 echo running >"$base/mode" ;;
*) echo "unexpected CLI call: $*" >&2; exit 90 ;;
esac
STUB
cat >"$test_dir/bin/ps" <<'STUB'
#!/bin/bash
base=${0%/*}/..
# Codex の検証が、停止の確認に読む一覧は、本物の ps から返す。
[[ $* != '-A -o pid,pgid,stat' && $* != '-A -o pid,pgid,stat,command' ]] || PATH=/bin:/usr/bin exec ps "$@"
cat "$base/process-env"
STUB
cat >"$test_dir/bin/claude" <<'STUB'
#!/bin/bash
base=${0%/*}/..
[[ $* == 'auth status' && $CLAUDE_CONFIG_DIR == */claude ]] || exit 91
if [[ -t 0 ]]; then
 echo 'error: EINVAL: invalid argument, kqueue' >&2
 exit 1
fi
printf 'notty\n' >"$base/claude-stdin"
if [[ -n ${TEST_CLAUDE_STDOUT:-} ]]; then
 cat "$TEST_CLAUDE_STDOUT"
 cat "$TEST_CLAUDE_STDERR" >&2
 exit "$TEST_CLAUDE_EXIT"
fi
if [[ -f $base/no-claude-auth ]]; then echo '{"loggedIn":false}'; else echo '{"loggedIn":true}'; fi
STUB
cat >"$test_dir/bin/codex" <<'STUB'
#!/bin/bash
base=${0%/*}/..
if [[ $* == 'app-server --strict-config --listen stdio://' ]]; then
 [[ $CODEX_HOME == */codex && ! -t 0 ]] || exit 93
 printf '%s\n' "$CODEX_HOME" >>"$base/codex-checks"
 mode=$(cat "$base/codex-strict" 2>/dev/null || echo ok)
 case $mode in
 ok) exit 0 ;;
 fail) echo 'Error: /agent/codex/config.toml:3:1: unknown configuration field `bogus`' >&2; exit 1 ;;
 silent) exit 1 ;;
 old) echo "error: unexpected argument '--strict-config' found" >&2; exit 2 ;;
 other2) echo 'error: another usage error' >&2; exit 2 ;;
 secret) echo 'invalid type: string "SYNTHETIC_SECRET_VALUE", expected a map' >&2; exit 1 ;;
 zombie-desc)
  # 子孫が先に終わり、TERM を無視する親が回収しない。子孫はゾンビのまま、親が動き続ける。子孫の PID は親が記録する。
  exec python3 -c 'import os, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
pid = os.fork()
if pid == 0:
    os._exit(0)
open(sys.argv[1], "w").write("%d\n" % pid)
open(sys.argv[2], "w").write("%d\n" % os.getpid())
time.sleep(300)' "$base/desc-pid" "$base/codex-pid" ;;
 term-*)
  # term-<親>-<子孫>。親は TERM で終わる（exit）か無視する（ignore）。子孫は、なし（none）、TERM のあと 0.5 秒で終わる（finish）、無視する（ignore）。
  spec=${mode#term-}; p=${spec%-*}; d=${spec#*-}
  case $d in
  finish) ( trap '/bin/sleep 0.5; echo done >"$base/desc-done"; exit 0' TERM; /bin/sleep 300 & wait ) & ;;
  ignore) ( trap '' TERM; exec /bin/sleep 300 ) & ;;
  esac
  [[ $d == none ]] || printf '%s\n' "$!" >"$base/desc-pid"
  printf '%s\n' "$$" >"$base/codex-pid"
  case $p in
  exit) trap 'exit 0' TERM; /bin/sleep 300 & wait $! ;;
  ignore) trap '' TERM; exec /bin/sleep 300 ;;
  esac ;;
 esac
fi
# 役と同じ引数で起こした app-server が hooks/list を返す。応答は codex-hooks-stub.py が作る。
if [[ $1 == app-server && $2 == --listen ]]; then exec python3 "$base/codex-hooks-stub.py" "$base" "$@"; fi
[[ $* == 'login status' && $CODEX_HOME == */codex ]] || exit 92
[[ ! -f $base/no-codex-auth ]]
STUB
cp "$root/tests/codex-hooks-stub.py" "$test_dir/codex-hooks-stub.py"
printf '#!/bin/bash\nexit 0\n' >"$test_dir/bin/sleep"
chmod +x "$test_dir/bin/"*
export PATH="$test_dir/bin:$PATH" TEMPLATE_AGENT_HOME="$test_dir/agent's home" TEMPLATE_DAEMON_ID_FILE="$test_dir/daemon.id"
export VSCODE_TEST_MARKER=must-not-be-inherited GH_CONFIG_DIR="$test_dir/human-gh"
printf daemon-a >"$TEMPLATE_DAEMON_ID_FILE"
# 人の gh の置き場は、セットアップが見つけられる場所に置く。端末のトークンは、手元の環境から切り離す。
mkdir -p "$GH_CONFIG_DIR"
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
cat >"$test_dir/run.sh" <<'RUN'
#!/bin/bash
set -euo pipefail
root=$1
source "${DRAW_UI:-$root/lib/ui.sh}"
source "$root/lib/check.sh"
source "$root/lib/host.sh"
die() { ui_phase_fail; ui_error "$*"; exit 1; }
mc() { multica "$@"; }
server_url=https://example.test
runtimes=${TEST_RUNTIMES:-[\"claude\",\"codex\"]}
command() {
 if [[ $* == "-v ${TEST_MISSING_RUNTIME:-__none__}" ]]; then return 1; fi
 builtin command "$@"
}
mktemp() {
 local path
 path=$(builtin command mktemp "$@") || return
 case $path in */claude-auth.*) printf '%s\n' "$path" >>"${TEMPLATE_DAEMON_ID_FILE%/*}/auth-work" ;; esac
 printf '%s\n' "$path"
}
if [[ ${TEST_AUTH_READER_FAIL:-no} == yes ]]; then
 test_python=$(type -P python3)
 python3() {
  if [[ ${2:-} == */claude-auth.*/stdout ]]; then
   echo 'reader exception: private-reader-value' >&2
   return 1
  fi
  "$test_python" "$@"
 }
fi
if [[ ${TEST_HOST_STEPS:-no} == yes ]]; then
 ui_init
 ui_steps_begin err 2 'ホストを準備'
 ui_phase_start 1
fi
[[ -z ${TEST_CODEX_SECONDS:-} ]] || codex_check_seconds=$TEST_CODEX_SECONDS
[[ -z ${TEST_CODEX_GRACE:-} ]] || codex_grace_seconds=$TEST_CODEX_GRACE
[[ -z ${TEST_CODEX_CONFIRM:-} ]] || codex_confirm_seconds=$TEST_CODEX_CONFIRM
# 拡張を使うセットアップと同じく、root を lib を持たない作業場所へ付け替え、原本は kit_root が指す（lib/extensions.sh）。
if [[ -n ${TEST_EXTENSION_WORK:-} ]]; then kit_root=$root; root=$TEST_EXTENSION_WORK; fi
if [[ ${2:-} == project ]]; then
 prepare_project_host project-order example/next
else
 prepare_host
fi
RUN
# TEST_LIMIT（秒）があるときは、その時間で打ち切る。応答しない特殊ファイルを読んで待つ実装を、止まらないテストにせず落とすため。
run() {
 if [[ -n ${TEST_LIMIT:-} ]]; then
  python3 -c 'import os, signal, subprocess, sys
child = subprocess.Popen(["/bin/bash", sys.argv[1], sys.argv[2], *sys.argv[6:]],
                         stdout=open(sys.argv[3], "w"), stderr=open(sys.argv[4], "w"),
                         start_new_session=True)
try:
    sys.exit(child.wait(timeout=int(sys.argv[5])))
except subprocess.TimeoutExpired:
    os.killpg(child.pid, signal.SIGKILL)
    child.wait()
    sys.exit(124)' "$test_dir/run.sh" "$root" "$test_dir/out" "$test_dir/err" "$TEST_LIMIT" "$@"
 else
  /bin/bash "$test_dir/run.sh" "$root" "$@" >"$test_dir/out" 2>"$test_dir/err"
 fi
}
deny() { if run; then exit 1; fi; [[ -s $test_dir/err ]]; }
set_mode() { printf '%s\n' "$1" >"$test_dir/mode"; : >"$test_dir/calls"; }
agent_env() { printf 'CODEX_HOME=%s/codex PATH=%s/bin:/usr/bin\n' "$TEMPLATE_AGENT_HOME" "$TEMPLATE_AGENT_HOME" >"$test_dir/process-env"; }
# ひな形に、スタブが返す hooks/list の値（役と同じ定義から決まる）を埋めた、書かれるはずの設定。
expected_codex_config() {
 python3 - "$root/common/codex/config.toml" "$TEMPLATE_AGENT_HOME" >"$test_dir/expected-config" <<'PY'
import hashlib
import sys

template = open(sys.argv[1], encoding="utf-8").read()
guard = sys.argv[2] + "/guard"
matcher = "^(Bash|shell|exec_command|local_shell)$"
lines = []
for event, snake, script, value in (("preToolUse", "pre_tool_use", "pre-tool-use", matcher), ("stop", "stop", "stop", None)):
    digest = hashlib.sha256(("%s|%s|%s" % (event, "'" + (guard + "/" + script).replace("'", "'\\''") + "'", value)).encode()).hexdigest()
    lines += ['[hooks.state."/<session-flags>/config.toml:%s:0:0"]' % snake, 'trusted_hash = "sha256:%s"' % digest]
sys.stdout.write(template.replace("{{HOOKS_STATE}}", "\n".join(lines)))
PY
}
# 人の設定（マークなし）に足す、信頼の行。値はスタブが返す hooks/list と同じ。
trust_lines() {
 expected_codex_config
 sed -n '/^\[hooks\.state\./,$p' "$test_dir/expected-config"
}
