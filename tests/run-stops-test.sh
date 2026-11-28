#!/usr/bin/env bash
# 原本のルートで bash tests/run-stops-test.sh を実行する。
# 役の実行の止まった理由を残すフックを確認する（設計は docs/agent-run-stops.md「止まった理由の記録」）。
# StopFailure のスクリプト（common/guard/stop-failure）が、入力の 13 の値と知らない値を表の理由で記録し、
# モデルの出力を写さず、記録できないときは何もせずに 0 で終わることを確認する。
# SessionStart と SessionEnd のスクリプト（common/guard/session-start・session-end）が、始めの長さを残し、
# 手数の上限で終わった実行だけを max_turns で記録することを確認する。
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
hook="$root/common/guard/stop-failure"
start_hook="$root/common/guard/session-start"
end_hook="$root/common/guard/session-end"
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/run-stops-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
home="$test_dir/home"
state="$test_dir/state"
mkdir -p "$home"

hook_rc=0
fail() {
	printf 'FAIL %s\n' "$1" >&2
	printf '  終了コード: %s\n  標準出力: %s\n  標準エラー: %s\n' "$hook_rc" "$(cat "$test_dir/out")" "$(cat "$test_dir/err")" >&2
	exit 1
}
# StopFailure のスクリプトを流す。引数: 入力の JSON。task_id と agent_id が空でなければ環境変数で渡す。
task_id=task-1
agent_id=agent-1
run_hook() {
	hook_rc=0
	env -i PATH="$PATH" HOME="$home" ${task_id:+MULTICA_TASK_ID="$task_id"} ${agent_id:+MULTICA_AGENT_ID="$agent_id"} \
		SQUAD_KIT_STATE_DIR="$state" "$hook" <<<"$1" >"$test_dir/out" 2>"$test_dir/err" || hook_rc=$?
}
expect_silent_pass() { # ラベル
	if [[ $hook_rc -ne 0 || -s $test_dir/out || -s $test_dir/err ]]; then fail "何も出さずに 0 で終わるはず（$1）"; fi
}
month_file() { printf '%s/run-stops/%s.jsonl' "$state" "$(date -u +%Y-%m)"; }
input() { # error の値（空なら欄なし） session_id
	jq -cn --arg e "$1" --arg s "$2" '{hook_event_name: "StopFailure", session_id: $s, error: $e,
		last_assistant_message: "SECRET-MODEL-OUTPUT /work/private/repo"} | if $e == "" then del(.error) else . end'
}
perm() { # ファイル 権限（stat の形式の差を吸収する）
	local mode
	mode=$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1")
	printf '%s' "$mode"
}

uuid=$(printf '%08x-%04x-%04x-%04x-%012x' 1 2 3 4 5) # 混入の検査に UUID の形を直書きしない

# --- 1. 13 の値は、そのまま理由になる ---

known=(authentication_failed oauth_org_not_allowed account_on_hold verification_required cloud_credential_error
	rate_limit billing_error overloaded server_error invalid_request model_not_found max_output_tokens unknown)
if [[ ${#known[@]} -ne 13 ]]; then fail '13 の値を並べるはず'; fi
for value in "${known[@]}"; do
	rm -rf -- "$state"
	run_hook "$(input "$value" "$uuid")"
	expect_silent_pass "$value"
	file=$(month_file)
	if [[ ! -f $file ]] || [[ $(wc -l <"$file" | tr -d ' ') -ne 1 ]]; then fail "$value: 記録が 1 行のはず"; fi
	if ! jq -e --arg v "$value" --arg s "$uuid" '
		(keys | sort) == ["agent", "reason", "session", "source", "task", "time"]
		and .reason == $v and .task == "task-1" and .agent == "agent-1" and .session == $s and .source == "claude"
		and (.time | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' "$file" >/dev/null; then
		fail "$value: 記録の欄が表のとおりではない: $(cat "$file")"
	fi
done
echo 'PASS StopFailure: 13 の値が、理由とその他の欄の表のとおりに記録される'

# --- 2. 知らない値と欄のない入力は unknown になる ---

for bad in made_up_reason RATE_LIMIT 'rate_limit ' ../etc; do
	rm -rf -- "$state"
	run_hook "$(input "$bad" "$uuid")"
	expect_silent_pass "$bad"
	if ! jq -e '.reason == "unknown"' "$(month_file)" >/dev/null; then fail "知らない値 '$bad' は unknown のはず: $(cat "$(month_file)")"; fi
done
rm -rf -- "$state"
run_hook "$(input '' "$uuid")"
expect_silent_pass 'error の欄なし'
if ! jq -e '.reason == "unknown"' "$(month_file)" >/dev/null; then fail 'error の欄がなければ unknown のはず'; fi
rm -rf -- "$state"
run_hook "{\"hook_event_name\":\"StopFailure\",\"session_id\":\"$uuid\",\"error\":[\"rate_limit\"]}"
expect_silent_pass 'error が文字列でない'
if ! jq -e '.reason == "unknown"' "$(month_file)" >/dev/null; then fail 'error が文字列でなければ unknown のはず'; fi
echo 'PASS StopFailure: 知らない値・欄のない入力・文字列でない値は unknown で記録される'

# --- 3. モデルの出力と入力の余分な欄は写さない ---

rm -rf -- "$state"
run_hook "$(input rate_limit "$uuid")"
expect_silent_pass 'モデルの出力'
if grep -rq 'SECRET-MODEL-OUTPUT\|/work/private' "$state"; then fail 'last_assistant_message を記録に写した'; fi
rm -rf -- "$state"
run_hook "{\"hook_event_name\":\"StopFailure\",\"session_id\":7,\"error\":\"rate_limit\"}"
expect_silent_pass 'session_id が文字列でない'
if ! jq -e '.session == ""' "$(month_file)" >/dev/null; then fail '文字列でない session_id は空にするはず'; fi
echo 'PASS StopFailure: last_assistant_message を写さず、文字列でない session_id は空で記録する'

# --- 4. 置き場と記録の権限、追記 ---

rm -rf -- "$state"
run_hook "$(input rate_limit "$uuid")"
run_hook "$(input overloaded "$uuid")"
expect_silent_pass '2 回目'
file=$(month_file)
if [[ $(wc -l <"$file" | tr -d ' ') -ne 2 ]] || [[ $(jq -r .reason "$file" | paste -sd, -) != rate_limit,overloaded ]]; then
	fail "2 回の記録が順に足されるはず: $(cat "$file")"
fi
if [[ $(perm "$state/run-stops") != 700 || $(perm "$file") != 600 ]]; then
	fail "置き場は 700、ファイルは 600 のはず（$(perm "$state/run-stops")、$(perm "$file")）"
fi
echo 'PASS StopFailure: 記録は順に足され、置き場は 700、ファイルは 600 になる'

# --- 5. 記録しない場合は、何も出さずに 0 で終わる ---

rm -rf -- "$state"
task_id=
run_hook "$(input rate_limit "$uuid")"
expect_silent_pass 'MULTICA_TASK_ID がない'
if [[ -e $state ]]; then fail 'MULTICA_TASK_ID がなければ、何も作らないはず'; fi
task_id=task-1

agent_id=
run_hook "$(input rate_limit "$uuid")"
expect_silent_pass 'MULTICA_AGENT_ID がない'
if ! jq -e '.agent == ""' "$(month_file)" >/dev/null; then fail 'MULTICA_AGENT_ID がなければ agent は空のはず'; fi
agent_id=agent-1

rm -rf -- "$state"
run_hook 'これは JSON ではない'
expect_silent_pass '壊れた入力'
run_hook '["StopFailure"]'
expect_silent_pass 'object でない入力'
run_hook ''
expect_silent_pass '空の入力'
run_hook "$(input rate_limit "$uuid" | jq -c '.hook_event_name = "Stop"')"
expect_silent_pass '別のフックの入力'
if [[ -e $state ]]; then fail '記録しない入力では、何も作らないはず'; fi

# 置き場が通常のファイルで、作れない
rm -rf -- "$state"
: >"$state"
run_hook "$(input rate_limit "$uuid")"
expect_silent_pass '置き場を作れない'
# 記録のファイルの場所がシンボリックリンクなら、たどらない
rm -rf -- "$state"
mkdir -p "$state/run-stops"
: >"$test_dir/elsewhere"
ln -s "$test_dir/elsewhere" "$(month_file)"
run_hook "$(input rate_limit "$uuid")"
expect_silent_pass '記録のファイルがシンボリックリンク'
if [[ -s $test_dir/elsewhere ]]; then fail 'シンボリックリンクの先に書いた'; fi
echo 'PASS StopFailure: タスクなし・壊れた入力・別のフック・書けない置き場では、何も出さずに 0 で終わる'

# --- SessionStart と SessionEnd ---

config="$test_dir/config"
proj="$config/projects/-work-repo"
sid=$(printf '%08x-%04x-%04x-%04x-%012x' 6 7 8 9 10)
other_sid=$(printf '%08x-%04x-%04x-%04x-%012x' 11 12 13 14 15)
transcript="$proj/$sid.jsonl"

# SessionStart か SessionEnd のスクリプトを流す。引数: スクリプト 入力の JSON
run_session() {
	hook_rc=0
	env -i PATH="$PATH" HOME="$home" ${task_id:+MULTICA_TASK_ID="$task_id"} ${agent_id:+MULTICA_AGENT_ID="$agent_id"} \
		CLAUDE_CONFIG_DIR="$config" SQUAD_KIT_STATE_DIR="$state" "$1" <<<"$2" >"$test_dir/out" 2>"$test_dir/err" || hook_rc=$?
}
start_input() { # session_id transcript_path
	jq -cn --arg s "$1" --arg p "$2" '{hook_event_name: "SessionStart", session_id: $s, transcript_path: $p, source: "startup"}'
}
end_input() { # session_id transcript_path
	jq -cn --arg s "$1" --arg p "$2" '{hook_event_name: "SessionEnd", session_id: $s, transcript_path: $p, reason: "other"}'
}
stamp() { jq -nr --argjson ago "$1" 'now - $ago | strftime("%Y-%m-%dT%H:%M:%S.000Z")'; }
line_user() { jq -cn --arg s "$1" --arg t "$(stamp 5)" '{type: "user", uuid: "line-user", sessionId: $s, timestamp: $t}'; }
line_max() { # session_id 何秒前か [添付の型]
	jq -cn --arg s "$1" --arg t "$(stamp "$2")" --arg a "${3:-max_turns_reached}" \
		'{type: "attachment", attachment: {type: $a, maxTurns: 1, turnCount: 1}, uuid: "line-max", sessionId: $s, timestamp: $t}'
}
line_admin() { jq -cn --arg s "$1" '{type: "last-prompt", sessionId: $s}'; }
start_file() { printf '%s/run-stops/start/%s' "$state" "$1"; }
fresh() {
	rm -rf -- "${state:?}" "${config:?}"
	mkdir -p "$proj"
}
set_start() { # session_id 長さ
	mkdir -p "$state/run-stops/start"
	printf '%s\n' "$2" >"$(start_file "$1")"
}
file_size() { wc -c <"$1" | tr -d ' '; }
expect_no_record() { # ラベル
	expect_silent_pass "$1"
	if [[ -e $(month_file) ]]; then fail "$1: 記録しないはず: $(cat "$(month_file)")"; fi
}
expect_record() { # ラベル
	expect_silent_pass "$1"
	if [[ ! -f $(month_file) ]] || [[ $(wc -l <"$(month_file)" | tr -d ' ') -ne 1 ]]; then fail "$1: 記録が 1 行のはず"; fi
	if ! jq -e --arg s "$sid" '
		(keys | sort) == ["agent", "reason", "session", "source", "task", "time"]
		and .reason == "max_turns" and .task == "task-1" and .agent == "agent-1" and .session == $s and .source == "claude"
		and (.time | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' "$(month_file)" >/dev/null; then
		fail "$1: 記録の欄が表のとおりではない: $(cat "$(month_file)")"
	fi
}

# --- 6. SessionStart は、記録の長さを残す ---

fresh
run_session "$start_hook" "$(start_input "$sid" "$transcript")"
expect_silent_pass '記録のファイルがまだない'
if [[ $(cat "$(start_file "$sid")") != 0 ]]; then fail "ファイルがないときは長さ 0 を書くはず: $(cat "$(start_file "$sid")")"; fi
if [[ $(perm "$state/run-stops/start") != 700 || $(perm "$(start_file "$sid")") != 600 ]]; then
	fail '始めの長さの置き場は 700、ファイルは 600 のはず'
fi
{ line_user "$sid"; line_admin "$sid"; } >"$transcript"
run_session "$start_hook" "$(start_input "$sid" "$transcript")"
expect_silent_pass '再開'
if [[ $(cat "$(start_file "$sid")") != "$(file_size "$transcript")" ]]; then fail '今のファイルの長さを書き直すはず'; fi
if [[ -e $(month_file) ]]; then fail 'SessionStart は理由の記録に書かないはず'; fi
echo 'PASS SessionStart: 始めの長さをバイトの数で書き（ファイルがなければ 0）、置き場は 700、ファイルは 600 になる'

# --- 7. SessionStart は、信頼できない入力では何も書かない ---

fresh
mkdir -p "$test_dir/outside"
: >"$test_dir/outside/$sid.jsonl"
ln -s "$test_dir/outside/$sid.jsonl" "$transcript"
for case in "UUID の形でない session_id|not-a-uuid|$proj/not-a-uuid.jsonl" \
	"置き場の外のファイル|$sid|$test_dir/outside/$sid.jsonl" \
	"名前が session_id と違う|$sid|$proj/$other_sid.jsonl" \
	"projects の下から外へのシンボリックリンク|$sid|$transcript" \
	"相対パス|$sid|projects/-work-repo/$sid.jsonl" \
	"空のパス|$sid|"; do
	IFS='|' read -r label case_sid case_path <<<"$case"
	rm -rf -- "${state:?}"
	run_session "$start_hook" "$(start_input "$case_sid" "$case_path")"
	expect_silent_pass "$label"
	if [[ -e $state ]]; then fail "$label: 何も書かないはず: $(find "$state" | head -3)"; fi
done
rm -f -- "${transcript:?}"
mkdir "$transcript"
run_session "$start_hook" "$(start_input "$sid" "$transcript")"
expect_silent_pass '通常のファイルでない'
if [[ -e $state ]]; then fail '通常のファイルでなければ、何も書かないはず'; fi
rmdir "$transcript"
run_session "$start_hook" "$(jq -cn --arg p "$transcript" '{hook_event_name: "SessionStart", session_id: 7, transcript_path: $p}')"
expect_silent_pass 'session_id が文字列でない'
run_session "$start_hook" "$(end_input "$sid" "$transcript")"
expect_silent_pass '別のフックの入力'
run_session "$start_hook" 'これは JSON ではない'
expect_silent_pass '壊れた入力'
task_id=
run_session "$start_hook" "$(start_input "$sid" "$transcript")"
expect_silent_pass 'MULTICA_TASK_ID がない'
task_id=task-1
if [[ -e $state ]]; then fail '記録しない入力では、何も作らないはず'; fi
: >"$state"
run_session "$start_hook" "$(start_input "$sid" "$transcript")"
expect_silent_pass '置き場を作れない'
echo 'PASS SessionStart: UUID の形でない・置き場の外・名前の違い・シンボリックリンク・通常でないファイル・タスクなし・書けない置き場では、何も出さず何も書かずに 0 で終わる'

# --- 8. SessionStart は、7 日より古い始めの長さのファイルだけを消す ---

fresh
old_sid=$(printf '%08x-%04x-%04x-%04x-%012x' 21 22 23 24 25)
recent_sid=$(printf '%08x-%04x-%04x-%04x-%012x' 31 32 33 34 35)
link_sid=$(printf '%08x-%04x-%04x-%04x-%012x' 41 42 43 44 45)
set_start "$old_sid" 5
set_start "$recent_sid" 6
set_start not-a-uuid 7
: >"$test_dir/link-target"
ln -s "$test_dir/link-target" "$(start_file "$link_sid")"
python3 -I -c '
import os, sys, time
directory = sys.argv[1]
for name, days in zip(sys.argv[2:], (8, 6, 30)):
    t = time.time() - days * 86400
    os.utime(os.path.join(directory, name), (t, t))
t = time.time() - 30 * 86400
os.utime(os.path.join(directory, sys.argv[5]), (t, t), follow_symlinks=False)
' "$state/run-stops/start" "$old_sid" "$recent_sid" not-a-uuid "$link_sid"
run_session "$start_hook" "$(start_input "$sid" "$transcript")"
expect_silent_pass '古いファイルの片付け'
if [[ -e $(start_file "$old_sid") ]]; then fail '8 日前のファイルは消すはず'; fi
if [[ ! -e $(start_file "$recent_sid") || ! -e $(start_file "$sid") ]]; then fail '6 日前のファイルと今回のファイルは残すはず'; fi
if [[ ! -e $(start_file not-a-uuid) ]]; then fail 'UUID の形でない名前は消さないはず'; fi
if [[ ! -L $(start_file "$link_sid") || ! -e $test_dir/link-target ]]; then fail 'シンボリックリンクは、消さず、たどらないはず'; fi
echo 'PASS SessionStart: 7 日より古い始めの長さのファイルだけを消す'

# --- 9. SessionEnd は、今回の実行で足された上限の添付だけを max_turns で記録する ---

# 始めから動いた実行の後ろに、上限の添付と、uuid のない行が続く
fresh
run_session "$start_hook" "$(start_input "$sid" "$transcript")"
{ line_user "$sid"; line_max "$sid" 5; line_admin "$sid"; } >"$transcript"
run_session "$end_hook" "$(end_input "$sid" "$transcript")"
expect_record '上限で終わった実行'
if [[ -e $(start_file "$sid") ]]; then fail 'SessionEnd は始めの長さのファイルを消すはず'; fi
if [[ $(perm "$state/run-stops") != 700 || $(perm "$(month_file)") != 600 ]]; then fail '置き場は 700、ファイルは 600 のはず'; fi

# 上限の添付が、始めの長さの位置から始まる
fresh
line_user "$sid" >"$transcript"
user_size=$(file_size "$transcript")
line_max "$sid" 5 >>"$transcript"
set_start "$sid" "$user_size"
run_session "$end_hook" "$(end_input "$sid" "$transcript")"
expect_record '添付が始めの長さの位置から始まる'
# 1 バイト後ろから始まる長さなら、その行は前の実行のもの
fresh
line_user "$sid" >"$transcript"
line_max "$sid" 5 >>"$transcript"
set_start "$sid" "$((user_size + 1))"
run_session "$end_hook" "$(end_input "$sid" "$transcript")"
expect_no_record '添付が始めの長さより前に始まる'

# 上限の添付のあとに user の行がある（再開して最後まで動いた）
fresh
line_max "$sid" 5 >"$transcript"
run_session "$start_hook" "$(start_input "$sid" "$transcript")"
line_user "$sid" >>"$transcript"
run_session "$end_hook" "$(end_input "$sid" "$transcript")"
expect_no_record '上限の添付のあとに user の行がある'
# 再開してすぐ終わり、新しい uuid の行がない
fresh
{ line_user "$sid"; line_max "$sid" 5; line_admin "$sid"; } >"$transcript"
run_session "$start_hook" "$(start_input "$sid" "$transcript")"
line_admin "$sid" >>"$transcript"
run_session "$end_hook" "$(end_input "$sid" "$transcript")"
expect_no_record '再開して新しい uuid の行がない'
if [[ -e $(start_file "$sid") ]]; then fail '記録しなくても、始めの長さのファイルは消すはず'; fi
# 別のセッションの添付、古い時刻、別の型の添付、添付でない行、欄のない行
for case in "別のセッションの添付|$(line_max "$other_sid" 5)" \
	"30 分前の添付|$(line_max "$sid" 1800)" \
	"型が違う添付|$(line_max "$sid" 5 environment)" \
	"添付でない行|$(line_max "$sid" 5 | jq -c '.type = "user"')" \
	"timestamp がない添付|$(line_max "$sid" 5 | jq -c 'del(.timestamp)')" \
	"uuid のない添付|$(line_max "$sid" 5 | jq -c 'del(.uuid)')"; do
	IFS='|' read -r label body <<<"$case"
	fresh
	run_session "$start_hook" "$(start_input "$sid" "$transcript")"
	{ line_user "$sid"; printf '%s\n' "$body"; } >"$transcript"
	run_session "$end_hook" "$(end_input "$sid" "$transcript")"
	expect_no_record "$label"
done
# 始めの長さがない、数として読めない
fresh
{ line_user "$sid"; line_max "$sid" 5; } >"$transcript"
run_session "$end_hook" "$(end_input "$sid" "$transcript")"
expect_no_record '始めの長さがない'
for bad in abc -1 '' '1 2' 12345678901234567; do
	fresh
	{ line_user "$sid"; line_max "$sid" 5; } >"$transcript"
	set_start "$sid" "$bad"
	run_session "$end_hook" "$(end_input "$sid" "$transcript")"
	expect_no_record "始めの長さが '$bad'"
	if [[ -e $(start_file "$sid") ]]; then fail "始めの長さが '$bad' でも、ファイルは消すはず"; fi
done
echo 'PASS SessionEnd: 始めの長さ以降の最後の uuid の行が、今のセッションの上限の添付のときだけ max_turns を記録する'

# --- 10. SessionEnd は、末尾の 64 KiB の窓でも行の位置を正しく読む ---

fresh
filler=$(line_user "$sid")
for ((i = 0; i < 1500; i++)); do printf '%s\n' "$filler"; done >"$transcript"
if [[ $(file_size "$transcript") -le 98304 ]]; then fail '窓より大きい埋めのファイルのはず'; fi
set_start "$sid" "$(file_size "$transcript")"
line_max "$sid" 5 >>"$transcript"
run_session "$end_hook" "$(end_input "$sid" "$transcript")"
expect_record '64 KiB より大きい記録の末尾の添付'
# 添付のあとに、窓より長い uuid のある行が続くとき（最後の uuid の行は添付でなく、窓にも収まらない）
fresh
set_start "$sid" 0
{ line_max "$sid" 5; jq -cn --arg pad "$(head -c 80000 /dev/zero | tr '\0' x)" '{type: "user", uuid: "line-long", pad: $pad}'; } >"$transcript"
run_session "$end_hook" "$(end_input "$sid" "$transcript")"
expect_no_record '添付のあとに長い uuid の行がある'
# 1 行が窓より長いとき、完全な行がなく記録しない
fresh
set_start "$sid" 0
jq -cn --arg s "$sid" --arg t "$(stamp 5)" --arg pad "$(head -c 80000 /dev/zero | tr '\0' x)" \
	'{type: "attachment", attachment: {type: "max_turns_reached"}, uuid: "line-max", sessionId: $s, timestamp: $t, pad: $pad}' >"$transcript"
run_session "$end_hook" "$(end_input "$sid" "$transcript")"
expect_no_record '1 行が窓より長い'
# 終わりの改行がない書きかけの行
fresh
run_session "$start_hook" "$(start_input "$sid" "$transcript")"
{ line_user "$sid"; line_max "$sid" 5; printf '{"type":"last-pro'; } >"$transcript"
run_session "$end_hook" "$(end_input "$sid" "$transcript")"
expect_record '終わりが書きかけの行'
echo 'PASS SessionEnd: 64 KiB より大きい記録でも末尾から読み、窓に収まらない行は記録しない'

# --- 11. SessionEnd は、置き場の外・名前の違い・シンボリックリンクの記録を読まず、記録しない場合は何も出さずに 0 で終わる ---

fresh
mkdir -p "$test_dir/outside"
good=$(printf '{"type":"x"}\n%s' "$(line_max "$sid" 5)")
printf '%s\n' "$good" >"$test_dir/outside/$sid.jsonl"
printf '%s\n' "$good" >"$proj/$other_sid.jsonl"
ln -s "$test_dir/outside/$sid.jsonl" "$transcript"
for case in "置き場の外のファイル|$sid|$test_dir/outside/$sid.jsonl" \
	"名前が session_id と違う|$sid|$proj/$other_sid.jsonl" \
	"projects の下から外へのシンボリックリンク|$sid|$transcript" \
	"相対パス|$sid|projects/-work-repo/$sid.jsonl" \
	"UUID の形でない session_id|not-a-uuid|$proj/not-a-uuid.jsonl"; do
	IFS='|' read -r label case_sid case_path <<<"$case"
	rm -rf -- "${state:?}"
	set_start "$case_sid" 0
	run_session "$end_hook" "$(end_input "$case_sid" "$case_path")"
	expect_no_record "$label"
done
rm -f -- "${transcript:?}"
mkdir "$transcript"
set_start "$sid" 0
run_session "$end_hook" "$(end_input "$sid" "$transcript")"
expect_no_record '通常のファイルでない'
rmdir "$transcript"
printf '%s\n' "$good" >"$transcript"
set_start "$sid" 0
run_session "$end_hook" "$(jq -cn --arg p "$transcript" '{hook_event_name: "SessionEnd", session_id: 7, transcript_path: $p}')"
expect_no_record 'session_id が文字列でない'
run_session "$end_hook" "$(jq -cn --arg s "$sid" '{hook_event_name: "SessionEnd", session_id: $s}')"
expect_no_record 'transcript_path がない'
run_session "$end_hook" "$(start_input "$sid" "$transcript")"
expect_no_record '別のフックの入力'
run_session "$end_hook" 'これは JSON ではない'
expect_no_record '壊れた入力'
run_session "$end_hook" ''
expect_no_record '空の入力'
set_start "$sid" 0
task_id=
run_session "$end_hook" "$(end_input "$sid" "$transcript")"
expect_no_record 'MULTICA_TASK_ID がない'
task_id=task-1
if [[ ! -e $(start_file "$sid") ]]; then fail 'MULTICA_TASK_ID がなければ、何も消さないはず'; fi
# 同じ記録と始めの長さで、正しい入力なら記録する（上の入力が原因で記録しなかったことを確認する）
run_session "$end_hook" "$(end_input "$sid" "$transcript")"
expect_record '正しい入力'
# 理由の記録の置き場に書けない
rm -rf -- "${state:?}"
set_start "$sid" 0
chmod 500 "$state/run-stops"
run_session "$end_hook" "$(end_input "$sid" "$transcript")"
chmod 700 "$state/run-stops"
expect_silent_pass '理由の記録の置き場に書けない'
# 理由の記録のファイルの場所がシンボリックリンクなら、たどらない
rm -rf -- "${state:?}"
set_start "$sid" 0
: >"$test_dir/elsewhere"
ln -s "$test_dir/elsewhere" "$(month_file)"
run_session "$end_hook" "$(end_input "$sid" "$transcript")"
expect_silent_pass '理由の記録のファイルがシンボリックリンク'
if [[ -s $test_dir/elsewhere ]]; then fail 'シンボリックリンクの先に書いた'; fi
echo 'PASS SessionEnd: 置き場の外・名前の違い・シンボリックリンク・壊れた入力・書けない置き場では、何も出さずに 0 で終わる'

# --- 12. SessionStart から SessionEnd まで ---

fresh
line_user "$sid" >"$transcript"
run_session "$start_hook" "$(start_input "$sid" "$transcript")"
{ line_user "$sid"; line_max "$sid" 5; line_admin "$sid"; } >>"$transcript"
run_session "$end_hook" "$(end_input "$sid" "$transcript")"
expect_record '始めに記録があった実行'
if [[ -e $(start_file "$sid") ]]; then fail '終わりで始めの長さのファイルを消すはず'; fi
echo 'PASS SessionStart と SessionEnd: 始めに記録があった実行でも、足された上限の添付を記録する'

echo 'PASS suite run-stops: 止まった理由を残すフックの確認'
