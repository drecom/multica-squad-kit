#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/host-daemon-test.XXXXXX")
exec 8>&2
trap 'test_exit=$?; if [[ $test_exit != 0 ]]; then cat "$test_dir/out" "$test_dir/err" >&8; fi; rm -rf -- "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/home" "$test_dir/away"
: >"$test_dir/out"
: >"$test_dir/err"
cat >"$test_dir/bin/multica" <<'STUB'
#!/bin/bash
set -euo pipefail
base=$(cd "${0%/*}/.." && pwd)
printf '%s\n' "$*" >>"$base/calls"
if [[ -f $base/fail && $(cat "$base/fail") == "$*" ]]; then exit 77; fi
delay_response() {
 exec python3 - "$base" "$*" <<'PY'
import pathlib, sys, time
base = pathlib.Path(sys.argv[1])
time.sleep(float((base / 'slow-delay').read_text()))
# 応答が最後まで続いたマーク。期限で止められた呼び出しは、ここに届かない。
with (base / 'slow-finished').open('a') as finished:
    finished.write(sys.argv[2] + '\n')
if sys.argv[2] == 'daemon status --output json':
    print((base / 'status.json').read_text())
elif sys.argv[2] == 'runtime list --output json':
    print('[]')
PY
}
if [[ -f $base/slow-call && -f $base/started-env.json && $(cat "$base/slow-call") == "$*" ]]; then delay_response "$@"; fi
case "$*" in
'user profile get --output json') printf '{"id":"member-a"}\n' ;;
'daemon status --output json')
 count=$(cat "$base/status-count"); count=$((count+1)); printf '%s\n' "$count" >"$base/status-count"
 file=$base/status.json
 if [[ $count -ge 2 && -f $base/next-status.json ]]; then file=$base/next-status.json; fi
 cat "$file"
 if [[ -f $base/status-nonzero ]]; then exit 1; fi ;;
'runtime list --output json')
 workspace=${MULTICA_WORKSPACE_ID:-}
 printf '%s\t%s\n' "$workspace" "${MULTICA_SERVER_URL:-}" >>"$base/runtime-queries"
 [[ $workspace == workspace-* ]] || exit 93
 if [[ -f $base/unreadable-workspace && $(cat "$base/unreadable-workspace") == "$workspace" ]]; then exit 77; fi
 if [[ -f $base/no-online ]]; then echo '[]'
 elif [[ -f $base/runtimes-$workspace.json ]]; then cat "$base/runtimes-$workspace.json"
 elif [[ $(jq -r .status "$base/status.json") != running ]]; then echo '[]'
 elif [[ -f $base/delay-workspace && $(cat "$base/delay-workspace") == "$workspace" && ! -f $base/was-delayed ]]; then
  touch "$base/was-delayed"
  echo '[{"id":"runtime-claude","owner_id":"member-a","daemon_id":"daemon-a","provider":"claude","status":"online"}]'
 else
  echo '[{"id":"runtime-claude","owner_id":"member-a","daemon_id":"daemon-a","provider":"claude","status":"online"},{"id":"runtime-codex","owner_id":"member-a","daemon_id":"daemon-a","provider":"codex","status":"online"}]'
 fi ;;
'daemon stop') echo '{"status":"stopped"}' >"$base/status.json" ;;
'daemon start')
 python3 -c 'import time; print(time.monotonic())' >"$base/started-at"
 jq -nc --arg home "$HOME" --arg user "${USER:-}" --arg shell "$SHELL" --arg path "$PATH" --arg codex "$CODEX_HOME" --arg server "$MULTICA_SERVER_URL" --arg ide "${VSCODE_TEST_MARKER:-}" --arg workspace "${MULTICA_WORKSPACE_ID:-}" --arg test "${TEST_DAEMON_DIR:-}" \
  '{home:$home,user:$user,shell:$shell,path:$path,codex:$codex,server:$server,ide:$ide,workspace:$workspace,test:$test}' >"$base/started-env.json"
 printf 'CODEX_HOME=%s PATH=%s\n' "$CODEX_HOME" "$PATH" >"$base/process-env"
 echo '{"status":"running","pid":4242,"daemon_id":"daemon-a","active_task_count":0,"server_url":"https://example.test"}' >"$base/status.json"
 rm -f "$base/status-nonzero"
 if [[ -f $base/slow-call && $(cat "$base/slow-call") == "$*" ]]; then delay_response "$@"; fi
 ;;
'daemon autostart status --output json')
case $TEST_AUTOSTART in
 enabled) printf '{"enabled":true,"mechanism":"launchd"}\n' ;;
 disabled) printf '{"enabled":false,"mechanism":"launchd"}\n' ;;
 failed) printf '{"enabled":true}\n'; exit 1 ;;
 invalid) printf 'invalid json\n' ;;
 missing) printf '{}\n' ;;
 string) printf '{"enabled":"true"}\n' ;;
 null) printf '{"enabled":null}\n' ;;
 multiple) printf '{"enabled":true}\n{"enabled":false}\n' ;;
 *) exit 91 ;;
esac
 ;;
*) exit 90 ;;
esac
STUB
cat >"$test_dir/bin/ps" <<'STUB'
#!/bin/bash
base=$(cd "${0%/*}/.." && pwd)
[[ $* == 'eww -o command= -p 4242' && ! -f $base/ps-fail ]] || exit 1
cat "$base/process-env"
STUB
cat >"$test_dir/bin/sleep" <<'STUB'
#!/bin/bash
base=$(cd "${0%/*}/.." && pwd)
printf '%s\n' "$*" >>"$base/sleeps"
STUB
# 見張りの待ち（/bin/sleep "$remaining"）の代わりに置き、渡された秒数を控えてから、その秒数だけ本当に待つ。
cat >"$test_dir/bin/watch-sleep" <<'STUB'
#!/bin/bash
base=$(cd "${0%/*}/.." && pwd)
printf '%s\n' "$1" >>"$base/watch-sleeps"
exec /bin/sleep "$1"
STUB
cat >"$test_dir/bin/gh" <<'STUB'
#!/bin/bash
printf 'gh\n' >>"$TEST_DAEMON_DIR/calls"
exit 92
STUB
chmod +x "$test_dir/bin/"*
export TEST_DAEMON_DIR=$test_dir TEST_AUTOSTART=disabled
export HOME=$test_dir/home TEMPLATE_AGENT_HOME="$test_dir/agent's home"
export TEMPLATE_DAEMON_ID_FILE=$test_dir/daemon.id TEMPLATE_DAEMON_ATTEMPTS=2 TEMPLATE_DAEMON_INTERVAL=0
export VSCODE_TEST_MARKER=must-not-be-inherited MULTICA_WORKSPACE_ID=must-not-be-inherited
export PATH="$test_dir/bin:$PATH"
unset MULTICA_SERVER_URL
# 原本の外へコピーして実行し、起動まで進んだあとの確認対象も控える。
cp "$root/common/host/start-daemon" "$test_dir/away/start-daemon"
# コピーの見張りの待ち（/bin/sleep）だけを、渡された秒数を控える補助に替える（秒数の式には触れない）。替える行が 1 行だけでなければ、原本の形が変わったので失敗にする。
sed -i.orig 's#/bin/sleep #"$TEST_DAEMON_DIR/bin/watch-sleep" #' "$test_dir/away/start-daemon"
[[ $(grep -c 'bin/watch-sleep"' "$test_dir/away/start-daemon") -eq 1 && $(grep -c '/bin/sleep' "$test_dir/away/start-daemon") -eq 0 ]]
rm -f "$test_dir/away/start-daemon.orig"
cat >>"$test_dir/away/start-daemon" <<'REPORT'
jq -nc --arg server "$server_url" --argjson requirements "$runtime_requirements" '{server:$server,requirements:$requirements}' >"$TEST_DAEMON_DIR/resolved.json"
REPORT
run() {
 local result=0
 : >"$test_dir/calls"
 : >"$test_dir/runtime-queries"
 : >"$test_dir/sleeps"
 : >"$test_dir/watch-sleeps"
 printf '0\n' >"$test_dir/status-count"
 if [[ ${PATH} != "$test_dir/tools" ]]; then snapshot >"$test_dir/run-before" || return 97; fi
 (cd "$test_dir/away" && /bin/bash ./start-daemon "$@" </dev/null) >"$test_dir/out" 2>"$test_dir/err" || result=$?
 if [[ ${PATH} != "$test_dir/tools" ]]; then
  snapshot >"$test_dir/run-after" || return 97
  cmp "$test_dir/run-before" "$test_dir/run-after" || return 97
 else
  return "$result"
 fi
 # 読み取りとデーモンの停止・起動以外の CLI は、どの経路でも呼ばない。
 if grep -Ev '^(daemon autostart status --output json|user profile get --output json|daemon status --output json|runtime list --output json|daemon stop|daemon start)$' "$test_dir/calls"; then return 98; fi
 return "$result"
}
deny() {
 local result=0
 run "$@" || result=$?
 [[ $result == 1 ]]
 grep -q '^エラー:' "$test_dir/err"
 [[ ! -s $test_dir/calls ]]
}
# 見張りに頼んだ待ちが、すべて期限（秒）に収まることを確認する。待ちは期限までの残りの整数秒（1 以上、期限以下）で、
# 負荷では変わらない。期限を超えて待たせる不具合（残りに秒を足すなど）は、期限を超える秒数になって失敗する。
watch_sleeps_within() {
 local deadline=$1
 [[ -s $test_dir/watch-sleeps ]] || return 1
 ! grep -Evx "[1-$deadline]" "$test_dir/watch-sleeps"
}
answer() {
 local workspace=$1 name=$2 server=$3 runtimes=$4
 mkdir -p "$TEMPLATE_AGENT_HOME/template/answers/$workspace"
 jq -nc --arg workspace "$workspace" --arg server "$server" --argjson runtimes "$runtimes" \
  '{schema:1,workspace_id:$workspace,server_url:$server,runtimes:$runtimes}' >"$TEMPLATE_AGENT_HOME/template/answers/$workspace/$name.json"
 touch -t 202601010001 "$TEMPLATE_AGENT_HOME/template/answers/$workspace/$name.json"
}
reset_host() {
 rm -rf -- "$TEMPLATE_AGENT_HOME"
 mkdir -p "$TEMPLATE_AGENT_HOME/template" "$TEMPLATE_AGENT_HOME/bin"
 printf '1.0.0\n' >"$TEMPLATE_AGENT_HOME/template/version"
 printf '#!/bin/bash\nexit 92\n' >"$TEMPLATE_AGENT_HOME/bin/gh"
 chmod +x "$TEMPLATE_AGENT_HOME/bin/gh"
 answer workspace-a project-a https://example.test '["claude"]'
 printf 'daemon-a\n' >"$TEMPLATE_DAEMON_ID_FILE"
 echo '{"status":"running","pid":4242,"daemon_id":"daemon-a","active_task_count":0,"server_url":"https://example.test"}' >"$test_dir/status.json"
 printf 'CODEX_HOME=%s/codex PATH=%s/bin:/usr/bin\n' "$TEMPLATE_AGENT_HOME" "$TEMPLATE_AGENT_HOME" >"$test_dir/process-env"
 rm -f "$test_dir/next-status.json" "$test_dir/status-nonzero" "$test_dir/no-online" "$test_dir/ps-fail" "$test_dir/fail" "$test_dir/unreadable-workspace" "$test_dir/delay-workspace" "$test_dir/was-delayed" "$test_dir/started-env.json" "$test_dir/slow-call" "$test_dir/slow-delay" "$test_dir/slow-finished" "$test_dir/"runtimes-*.json
}
snapshot() {
 python3 - "${TEMPLATE_AGENT_HOME:-$HOME/.multica-agent}" <<'PY'
import hashlib, json, os, sys
from pathlib import Path
base = Path(sys.argv[1])
rows = []
for p in sorted(base.rglob('*')):
    if not p.is_file():
        continue
    # 権限・大きさ・更新の時刻はすべてのファイルで控える。中身は、読めるファイルだけ控える。
    st = p.stat()
    digest = hashlib.sha256(p.read_bytes()).hexdigest() if os.access(p, os.R_OK) else None
    rows.append((str(p.relative_to(base)), oct(st.st_mode & 0o7777), st.st_size, st.st_mtime_ns, digest))
print(json.dumps(rows))
PY
}

reset_host
deny unexpected
grep -q '使い方:' "$test_dir/err"
echo 'PASS host-daemon: 引数を渡すと使い方を出して 1 で終わる'
mkdir -p "$test_dir/tools"
for missing in multica jq; do
 rm -f "$test_dir/tools/multica" "$test_dir/tools/jq"
 if [[ $missing == jq ]]; then
  ln -s "$test_dir/bin/multica" "$test_dir/tools/multica"
 else
  ln -s "$(command -v jq)" "$test_dir/tools/jq"
 fi
 saved_path=$PATH
 export PATH=$test_dir/tools
 result=0
 run || result=$?
 export PATH=$saved_path
 [[ $result == 1 && ! -s $test_dir/calls ]]
 grep -q "$missing がありません" "$test_dir/err"
done
echo 'PASS host-daemon: multica と jq がなければ導入を案内し、起動しない'

for absent in template/version bin/gh template/answers; do
 reset_host
 rm -rf -- "$TEMPLATE_AGENT_HOME/$absent"
 deny
 grep -q 'セットアップが済んでいません' "$test_dir/err"
done
echo 'PASS host-daemon: セットアップが済んでいない記録・ガード・答えの各場面で起動しない'

for state in running stopped; do
 reset_host
 if [[ $state == stopped ]]; then echo '{"status":"stopped","pid":null}' >"$test_dir/status.json"; fi
 chmod 644 "$TEMPLATE_AGENT_HOME/bin/gh"
 deny
 grep -q 'セットアップが済んでいません' "$test_dir/err"
done
echo 'PASS host-daemon: ガードに実行権限がなければ CLI を呼ばず、停止も起動もせずセットアップを案内する'

reset_host
snapshot >"$test_dir/before"
run
jq -e '.server=="https://example.test" and ([.requirements[]|{workspace_id,runtimes}]==[{workspace_id:"workspace-a",runtimes:["claude"]}])' "$test_dir/resolved.json" >/dev/null
[[ ! -s $test_dir/err ]]
grep -qx 'daemon autostart status --output json' "$test_dir/calls"
snapshot >"$test_dir/after"
cmp "$test_dir/before" "$test_dir/after"
echo 'PASS host-daemon: gh を呼ばず、原本の外の入口だけで答えを読み、書き換えない'

answer workspace-a old https://old.test '["codex"]'
touch -t 202501010001 "$TEMPLATE_AGENT_HOME/template/answers/workspace-a/old.json"
run
jq -e '.server=="https://example.test" and .requirements[0].runtimes==["claude"]' "$test_dir/resolved.json" >/dev/null
grep -q 'old.json' "$test_dir/err"
echo 'PASS host-daemon: 最新の答えの接続先を使い、別の接続先の答えは名前を出して除く'
touch -r "$TEMPLATE_AGENT_HOME/template/answers/workspace-a/project-a.json" "$TEMPLATE_AGENT_HOME/template/answers/workspace-a/old.json"
deny
grep -q '最後に流したセットアップの接続先を決められません' "$test_dir/err"
echo 'PASS host-daemon: 接続先を決められない同時刻の答えでは起動せず、直し方を出す'

reset_host
for value in https://other.test ''; do
 export MULTICA_SERVER_URL=$value
 deny
 grep -q '環境変数 MULTICA_SERVER_URL' "$test_dir/err"
done
export MULTICA_SERVER_URL=https://example.test
run
unset MULTICA_SERVER_URL
echo 'PASS host-daemon: 環境変数の接続先が違えば止まり、同じなら続ける'

answer workspace-a codex https://example.test '["codex"]'
answer workspace-b project-b https://example.test '["codex"]'
answer workspace-c legacy https://example.test '["claude"]'
jq 'del(.runtimes)' "$TEMPLATE_AGENT_HOME/template/answers/workspace-c/legacy.json" >"$test_dir/legacy"
mv "$test_dir/legacy" "$TEMPLATE_AGENT_HOME/template/answers/workspace-c/legacy.json"
run
jq -e '[.requirements[]|{workspace_id,runtimes}]==[{workspace_id:"workspace-a",runtimes:["claude","codex"]},{workspace_id:"workspace-b",runtimes:["codex"]},{workspace_id:"workspace-c",runtimes:["claude","codex"]}]' "$test_dir/resolved.json" >/dev/null
echo 'PASS host-daemon: ランタイムを合わせる対象をワークスペースごとに集め、古い答えは両方にする'

# 使わない答えが最新でも、正しい答えの接続先と対象を使い、原因に合う警告だけをファイル名付きで 1 件出す。
unreadable_notice='答えのファイルを読めないので、使いません'
shape_notice='答えのファイルの形が合わないので、使いません。不要なら消し、使うなら消してからセットアップを流し直してください'
# 警告の種類（unreadable か shape）と、bad.json に書く中身を受け取り、どちらの警告が出るかを確認する。
bad_case() {
 local kind=$1 content=$2
 reset_host
 printf '%s\n' "$content" >"$TEMPLATE_AGENT_HOME/template/answers/workspace-a/bad.json"
 snapshot >"$test_dir/before"
 run
 jq -e '.server=="https://example.test" and .requirements[0].runtimes==["claude"]' "$test_dir/resolved.json" >/dev/null
 if [[ $kind == unreadable ]]; then
  grep -q "^注意: $unreadable_notice: .*/bad.json\$" "$test_dir/err"
  ! grep -q '形が合わない' "$test_dir/err"
 else
  grep -q "^注意: $shape_notice: .*/bad.json\$" "$test_dir/err"
  ! grep -q '読めない' "$test_dir/err"
 fi
 [[ $(grep -c '^注意:' "$test_dir/err") -eq 1 ]]
 snapshot >"$test_dir/after"
 cmp "$test_dir/before" "$test_dir/after"
}
# 読めない群: 壊れた JSON、値が 2 つ、空のファイル、開けないファイル。
bad_case unreadable 'broken json'
bad_case unreadable $'{}\n{}'
bad_case unreadable ''
reset_host
: >"$TEMPLATE_AGENT_HOME/template/answers/workspace-a/bad.json"
run
grep -q "^注意: $unreadable_notice: .*/bad.json\$" "$test_dir/err"
if [[ $(id -u) != 0 ]]; then
 reset_host
 cp "$TEMPLATE_AGENT_HOME/template/answers/workspace-a/project-a.json" "$TEMPLATE_AGENT_HOME/template/answers/workspace-a/bad.json"
 chmod 000 "$TEMPLATE_AGENT_HOME/template/answers/workspace-a/bad.json"
 snapshot >"$test_dir/before"
 result=0
 run || result=$?
 snapshot >"$test_dir/after"
 chmod 644 "$TEMPLATE_AGENT_HOME/template/answers/workspace-a/bad.json"
 [[ $result == 0 ]]
 cmp "$test_dir/before" "$test_dir/after"
 jq -e '.server=="https://example.test"' "$test_dir/resolved.json" >/dev/null
 grep -q "^注意: $unreadable_notice: .*/bad.json\$" "$test_dir/err"
 ! grep -q '形が合わない' "$test_dir/err"
else
 echo 'SKIP host-daemon: root では開けないファイルの場面を確認できない'
fi
# 形が合わない群: オブジェクトでない、schema が違う、値が不正。
for invalid in 'null' '[]' '{"schema":2}' \
 '{"schema":1,"workspace_id":"workspace-a","server_url":"http://example.test"}' \
 '{"schema":1,"workspace_id":"workspace-a","server_url":"https://user@example.test"}' \
 '{"schema":1,"workspace_id":"workspace-a","server_url":"https://example.test?query"}' \
 '{"schema":1,"workspace_id":"wrong","server_url":"https://example.test"}' \
 '{"schema":1,"workspace_id":"workspace-a","server_url":"https://other.test","runtimes":[]}' \
 '{"schema":1,"workspace_id":"workspace-a","server_url":"https://other.test","runtimes":["codex","codex"]}' \
 '{"schema":1,"workspace_id":"workspace-a","server_url":"https://other.test","runtimes":["other"]}' \
 '{"schema":1,"workspace_id":"workspace-a","server_url":"https://other.test","runtimes":null}' \
 ; do
 bad_case shape "$invalid"
done
rm -f "$TEMPLATE_AGENT_HOME/template/answers/workspace-a/project-a.json"
deny
grep -q 'セットアップが済んでいません' "$test_dir/err"
echo 'PASS host-daemon: 読めない答えは「読めないので」、形の合わない答えは「形が合わないので」と直し方を、名前付きで出して除き、正しい答えがなければセットアップを案内する'

# 拡張の記録は答えとして読まず、警告も出さない。最新の時刻でも、接続先と対象は変わらない。
reset_host
printf '%s\n' '{"roles":{},"autopilots":{}}' >"$TEMPLATE_AGENT_HOME/template/answers/workspace-a/project-a-membera.extensions.json"
snapshot >"$test_dir/before"
run
jq -e '.server=="https://example.test" and ([.requirements[]|{workspace_id,runtimes}]==[{workspace_id:"workspace-a",runtimes:["claude"]}])' "$test_dir/resolved.json" >/dev/null
[[ ! -s $test_dir/err ]]
snapshot >"$test_dir/after"
cmp "$test_dir/before" "$test_dir/after"
echo 'PASS host-daemon: 正しい答えと並ぶ最新の拡張の記録に警告を出さず、接続先と対象を変えない'
for content in 'broken json' '{"schema":2}'; do
 reset_host
 printf '%s\n' "$content" >"$TEMPLATE_AGENT_HOME/template/answers/workspace-a/project-a-membera.extensions.json"
 run
 [[ ! -s $test_dir/err ]]
done
echo 'PASS host-daemon: 拡張の記録は中身を見ず、壊れていても警告を出さない'
reset_host
rm -f "$TEMPLATE_AGENT_HOME/template/answers/workspace-a/project-a.json"
printf '%s\n' '{"roles":{},"autopilots":{}}' >"$TEMPLATE_AGENT_HOME/template/answers/workspace-a/project-a-membera.extensions.json"
snapshot >"$test_dir/before"
deny
grep -q 'セットアップが済んでいません' "$test_dir/err"
! grep -q 'extensions.json' "$test_dir/err"
snapshot >"$test_dir/after"
cmp "$test_dir/before" "$test_dir/after"
echo 'PASS host-daemon: 拡張の記録だけがあるときはセットアップを案内して止まる'

reset_host
for mode in enabled disabled failed invalid missing string null multiple; do
 export TEST_AUTOSTART=$mode
 snapshot >"$test_dir/before"
 run
 [[ $(wc -l <"$test_dir/calls") -eq 4 ]]
 grep -qx 'daemon autostart status --output json' "$test_dir/calls"
 case $mode in
  enabled)
   grep -q '^注意: CLI の自動起動が有効です' "$test_dir/err"
   grep -q 'multica daemon autostart disable' "$test_dir/err" ;;
  disabled) [[ ! -s $test_dir/err ]] ;;
  *) grep -q '^注意: CLI の自動起動の状態を読めませんでした' "$test_dir/err" ;;
 esac
 snapshot >"$test_dir/after"
 cmp "$test_dir/before" "$test_dir/after"
 echo "PASS host-daemon: 自動起動 $mode の案内どおりに続け、設定を変えない"
done

fail_run() {
 local result=0
 run || result=$?
 [[ $result == 1 ]]
 grep -q '^エラー:' "$test_dir/err"
}
no_daemon_change() {
 fail_run
 ! grep -Eq '^daemon (stop|start)$' "$test_dir/calls"
}
stopped() { echo '{"status":"stopped","pid":null}' >"$test_dir/status.json"; }

export TEST_AUTOSTART=disabled
reset_host
run
! grep -Eq '^daemon (stop|start)$' "$test_dir/calls"
[[ ! -s $test_dir/sleeps ]]
grep -qx '接続先: https://example.test' "$test_dir/out"
echo 'PASS host-daemon: そろっているときは停止も起動も待機もしない'

reset_host
stopped
run
[[ $(grep -cx 'daemon start' "$test_dir/calls") -eq 1 ]]
! grep -qx 'daemon stop' "$test_dir/calls"
jq -e --arg home "$HOME" --arg agent "$TEMPLATE_AGENT_HOME" --arg path "$PATH" '
 .home==$home and .shell=="/bin/zsh" and .path==($agent+"/bin:"+$path) and
 .codex==($agent+"/codex") and .server=="https://example.test" and
 .ide=="" and .workspace=="" and .test==""' "$test_dir/started-env.json" >/dev/null
grep -qx 'ランタイム: workspace-a の claude' "$test_dir/out"
echo 'PASS host-daemon: 止まっているときに一度起動し、起動の環境にガード・CODEX_HOME・接続先をそろえ、シェルの変数を渡さない'

: >"$test_dir/calls"
MULTICA_WORKSPACE_ID=workspace-a MULTICA_SERVER_URL=https://example.test /bin/bash -c '
set -euo pipefail
source "$1/lib/check.sh"
source "$1/lib/host.sh"
die() { printf "%s\n" "$*" >&2; exit 1; }
mc() { multica "$@"; }
server_url=https://example.test
runtimes='"'"'["claude"]'"'"'
host_paths
prepare_daemon
' -- "$root" >"$test_dir/out" 2>"$test_dir/err"
! grep -Eq '^daemon (stop|start)$' "$test_dir/calls"
echo 'PASS host-daemon: 入口の起動後にセットアップに通すと、停止も起動もしない'

reset_host
printf 'PATH=/usr/bin\n' >"$test_dir/process-env"
run
[[ $(grep -E '^daemon (stop|start)$' "$test_dir/calls") == $'daemon stop\ndaemon start' ]]
echo 'PASS host-daemon: 環境がそろわずタスク数 0 なら、止めて起動し直す'

for counts in '{"active_task_count":0,"running_task_count":1,"resource_wait_task_count":2}' \
 '{}' '{"active_task_count":"0"}'; do
 reset_host
 printf 'PATH=/usr/bin\n' >"$test_dir/process-env"
 jq --argjson counts "$counts" 'del(.active_task_count)+$counts' "$test_dir/status.json" >"$test_dir/new-status"
 mv "$test_dir/new-status" "$test_dir/status.json"
 no_daemon_change
 if [[ $counts == *resource_wait* ]]; then
  grep -q 'タスクが動いています（2 件）' "$test_dir/err"
  grep -q 'タスクが終わってから' "$test_dir/err"
 else
  grep -q 'タスクの数を読めません' "$test_dir/err"
 fi
done
echo 'PASS host-daemon: タスクがあるときは最大値を読み、不明なときも停止しない'

reset_host
printf 'PATH=/usr/bin\n' >"$test_dir/process-env"
jq '.active_task_count=1' "$test_dir/status.json" >"$test_dir/next-status.json"
no_daemon_change
[[ $(cat "$test_dir/status-count") -eq 2 ]]
echo 'PASS host-daemon: 止める直前に状態を読み直し、新しいタスクがあれば止めない'

for when in initial reread; do
 reset_host
 if [[ $when == initial ]]; then destination=$test_dir/new-status; else
  destination=$test_dir/next-status.json
  printf 'PATH=/usr/bin\n' >"$test_dir/process-env"
 fi
 jq '.server_url="https://other.test"' "$test_dir/status.json" >"$destination"
 if [[ $when == initial ]]; then mv "$destination" "$test_dir/status.json"; fi
 no_daemon_change
 grep -q '別の接続先（https://other.test）' "$test_dir/err"
done
echo 'PASS host-daemon: 別の接続先なら、初回も停止直前も止めも起動もしない'

reset_host
stopped
echo '[{"id":"desktop","owner_id":"member-a","daemon_id":"daemon-a","provider":"codex","status":"online"}]' >"$test_dir/runtimes-workspace-a.json"
no_daemon_change
grep -q 'CLI 以外のデーモン' "$test_dir/err"
grep -q 'アプリを終了' "$test_dir/err"
grep -q '1 分ほど待って' "$test_dir/err"
echo 'PASS host-daemon: CLI 以外のデーモンが動いていれば、停止も起動もせず案内する'

reset_host
stopped
touch "$test_dir/status-nonzero"
run
grep -qx 'daemon start' "$test_dir/calls"
reset_host
jq 'del(.daemon_id)' "$test_dir/status.json" >"$test_dir/new-status"
mv "$test_dir/new-status" "$test_dir/status.json"
run
! grep -Eq '^daemon (stop|start)$' "$test_dir/calls"
echo 'PASS host-daemon: 止まっている状態の非 0 応答と、ファイルのデーモン ID を読める'

reset_host
stopped
answer workspace-a codex https://example.test '["codex"]'
printf 'workspace-a\n' >"$test_dir/delay-workspace"
run
[[ $(wc -l <"$test_dir/sleeps") -eq 1 ]]
[[ $(grep -c '^workspace-a' "$test_dir/runtime-queries") -eq 3 ]]
grep -qx 'ランタイム: workspace-a の claude、codex' "$test_dir/out"
echo 'PASS host-daemon: Claude だけと Codex だけのプロジェクトでは、片方だけがオンラインでも待つ'

reset_host
stopped
answer workspace-a codex https://example.test '["codex"]'
answer workspace-b project-b https://example.test '["codex"]'
printf 'workspace-b\n' >"$test_dir/delay-workspace"
run
[[ $(wc -l <"$test_dir/sleeps") -eq 1 ]]
[[ $(grep -c '^workspace-b' "$test_dir/runtime-queries") -eq 3 ]]
grep -qx 'ランタイム: workspace-a の claude、codex' "$test_dir/out"
grep -qx 'ランタイム: workspace-b の codex' "$test_dir/out"
awk -F '\t' '$2!="https://example.test" {exit 1}' "$test_dir/runtime-queries"
echo 'PASS host-daemon: ランタイムを合わせる対象すべてが各ワークスペースでオンラインになるまで待つ'

reset_host
stopped
answer workspace-a codex https://example.test '["codex"]'
touch "$test_dir/no-online"
fail_run
[[ $(wc -l <"$test_dir/sleeps") -eq 2 ]]
[[ $(grep -cx 'daemon start' "$test_dir/calls") -eq 1 ]]
! grep -qx 'daemon stop' "$test_dir/calls"
grep -q 'ランタイムが 60 秒のうちにオンラインになりません' "$test_dir/err"
grep -q 'workspace-a の claude' "$test_dir/err"
grep -q 'workspace-a の codex' "$test_dir/err"
grep -q 'project-a.json' "$test_dir/err"
grep -q 'codex.json' "$test_dir/err"
grep -q 'multica daemon logs' "$test_dir/err"
echo 'PASS host-daemon: 時間切れなら、足りないランタイムと答えの名前、確認する場所を出し、起動したデーモンを止めない'

# 応答を待つ時間も、起動開始からの共通の期限に含める。
for slow_call in 'daemon start' 'daemon status --output json' 'runtime list --output json'; do
 reset_host
 stopped
 touch "$test_dir/no-online"
 printf '%s\n' "$slow_call" >"$test_dir/slow-call"
 printf '8\n' >"$test_dir/slow-delay"
 TEMPLATE_DAEMON_TIMEOUT=2 TEMPLATE_DAEMON_ATTEMPTS=30 fail_run
 # 期限の前に終わらないことは経過時間で、期限で止まったこと（8 秒の応答を待っていないこと）は応答の終わりのマークがないことで確認する。
 # 経過時間の上限は、負荷で伸びるので置かない。期限を超えて待たせないことは、見張りに頼んだ待ちの秒数で確認する。
 python3 - "$test_dir/started-at" <<'PY'
import pathlib, sys, time
elapsed = time.monotonic() - float(pathlib.Path(sys.argv[1]).read_text())
assert elapsed >= 0.5, elapsed
PY
 [[ ! -e $test_dir/slow-finished ]]
 watch_sleeps_within 2
 grep -q 'ランタイムが 60 秒のうちにオンラインになりません' "$test_dir/err"
 [[ $(grep -cx 'daemon start' "$test_dir/calls") -eq 1 ]]
 ! grep -qx 'daemon stop' "$test_dir/calls"
 echo "PASS host-daemon: $slow_call の応答が止まっても、起動開始からの期限で終了する"
done

reset_host
stopped
answer workspace-b project-b https://example.test '["codex"]'
answer workspace-c project-c https://example.test '["codex"]'
answer workspace-d project-d https://example.test '["codex"]'
touch "$test_dir/no-online"
printf 'runtime list --output json\n' >"$test_dir/slow-call"
printf '0.6\n' >"$test_dir/slow-delay"
TEMPLATE_DAEMON_TIMEOUT=2 TEMPLATE_DAEMON_ATTEMPTS=30 fail_run
python3 - "$test_dir/started-at" <<'PY'
import pathlib, sys, time
elapsed = time.monotonic() - float(pathlib.Path(sys.argv[1]).read_text())
assert elapsed >= 0.5, elapsed
PY
# 起動のあとの 1 回の応答は 0.6 秒で、4 つのワークスペースを読むと 1 周が 2.4 秒かかり、期限（2 秒）を超える。呼び出しは
# 前の呼び出しが返ってから、期限の前にだけ始まるので、期限が呼び出しごとに延びていなければ、起動のあとに始まる数は、
# 期限の 2 秒を 0.6 秒で割った 4 回までになる。延びていれば、30 周で 120 回に届く。
# 負荷で応答が遅れるほど数は減るので、この上限は負荷で破れない。
[[ $(awk '$0=="daemon start" {started=1; next} started && $0=="runtime list --output json" {count++} END {print count+0}' "$test_dir/calls") -le 4 ]]
watch_sleeps_within 2
grep -q 'ランタイムが 60 秒のうちにオンラインになりません' "$test_dir/err"
! grep -qx 'daemon stop' "$test_dir/calls"
echo 'PASS host-daemon: 複数ワークスペースの応答遅延を足しても、期限を延ばさない'

reset_host
stopped
echo '[{"id":"other-member","owner_id":"member-b","daemon_id":"daemon-a","provider":"claude","status":"online"},{"id":"other-host","owner_id":"member-a","daemon_id":"daemon-b","provider":"claude","status":"online"},{"id":"offline","owner_id":"member-a","daemon_id":"daemon-a","provider":"claude","status":"offline"}]' >"$test_dir/runtimes-workspace-a.json"
fail_run
grep -qx 'daemon start' "$test_dir/calls"
! grep -q 'CLI 以外のデーモン' "$test_dir/err"
grep -q 'workspace-a の claude' "$test_dir/err"
echo 'PASS host-daemon: 別の人・別のホスト・オフラインのランタイムを数えない'

reset_host
echo workspace-a >"$test_dir/unreadable-workspace"
no_daemon_change
grep -q 'ワークスペース（workspace-a）' "$test_dir/err"
grep -q 'template/answers' "$test_dir/err"
echo 'PASS host-daemon: ワークスペースを読めなければ、その ID と答えのディレクトリを案内して止まる'

for bad_status in 'broken json' '{"status":"unknown"}' '{"status":"running","pid":"4242"}'; do
 reset_host
 printf '%s\n' "$bad_status" >"$test_dir/status.json"
 no_daemon_change
done
reset_host
echo '{}' >"$test_dir/runtimes-workspace-a.json"
no_daemon_change
echo 'PASS host-daemon: 状態やランタイムの応答が不正なら、停止も起動もしない'

for failure in 'user profile get --output json' 'daemon status --output json' 'daemon stop' 'daemon start'; do
 reset_host
 if [[ $failure == 'daemon stop' ]]; then printf 'PATH=/usr/bin\n' >"$test_dir/process-env"; fi
 if [[ $failure == 'daemon start' ]]; then stopped; fi
 printf '%s\n' "$failure" >"$test_dir/fail"
 fail_run
done
echo 'PASS host-daemon: CLI の読み取り・停止・起動の失敗を成功にしない'

# 通常の置き場も使える。テスト用の置き場に依存しない。
reset_host
mv "$TEMPLATE_AGENT_HOME" "$HOME/.multica-agent"
unset TEMPLATE_AGENT_HOME
run
jq -e '.server=="https://example.test"' "$test_dir/resolved.json" >/dev/null
echo 'PASS host-daemon: 置き場を指定しなければ HOME の導入を読む'
