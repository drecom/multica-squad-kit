#!/usr/bin/env bash
# 原本のルートで bash tests/run-stops-test.sh を実行する。
# 役の実行の止まった理由を残すフックを確認する（設計は docs/agent-run-stops.md「止まった理由の記録」）。
# 今は StopFailure のスクリプト（common/guard/stop-failure）が、入力の 13 の値と知らない値を表の理由で記録し、
# モデルの出力を写さず、記録できないときは何もせずに 0 で終わることを確認する。
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
hook="$root/common/guard/stop-failure"
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

echo 'PASS suite run-stops: 止まった理由を残すフックの確認'
