#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-usage-wait-jq-test.sh で実行する。
# squad-usage-wait が、大きな JSON を jq の引数に渡さず、jq の失敗を 0 回の繰り返しや空の値として読み流さないことを確認する。
# 値ごとの渡し方の表は docs/usage-answer.md の「jq への渡し方」。共通の準備は tests/squad-usage-wait-test-lib.sh。
# 引数の上限（131,072 バイト）を超える呼び出しは、jq の包みが拒み、終わるときに記録が空であることを確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/squad-usage-wait-test-lib.sh"

reset

script=$root/common/monitor/squad-usage-wait

# ---- 静的な確認（T3）。プロセス置換（done < <(）と、関数の引数の頭にあるコマンド置換（"$(jq）を使わない。
# どちらも、jq の失敗を、0 回の繰り返しや空の値と区別できない。
if grep -nE 'done < <\(' "$script"; then fail 'プロセス置換で繰り返している'; fi
if grep -nE '"\$\(jq' "$script"; then fail '関数の引数の中で jq のコマンド置換を使っている'; fi
# --argjson と --arg の値は、数・時刻・ID・名前・使用率の読み取りの決まった形・記録 1 件に限る。件数の増える配列は、標準入力で渡す。
# 新しく足す値は、この一覧に足すと同時に、docs/usage-answer.md の「jq への渡し方」の表にも足す。
bounded_values() {
	grep -oE -- '--(argjson|arg) [a-z_]+ "[^"]*"' "$script" | sed -E 's/^--(argjson|arg) [a-z_]+ //' | sort -u
}
while IFS= read -r value; do
	case $value in
	'"$1"' | '"$FAIL_SAFE_SECONDS"' | '"$WAIT_MARK"' | '"$answer_id"' | '"$answered"' | '"$claude_role"' | '"$codex_role"' | '"$cutoff"' | '"$expiry"') ;;
	'"$id"' | '"$identifier"' | '"$issue"' | '"$keep"' | '"$key"' | '"$leader"' | '"$new_record"' | '"$now"' | '"$process"' | '"$role"') ;;
	'"$round"' | '"$since"' | '"$squad"' | '"$task_now"' | '"$usage"' | '"$usage_reason"' | '"$use_id"' | '"$utask"' | '"$verdict"') ;;
	'"claude-$suffix"' | '"codex-$suffix"' | '"$([[ -n $carried ]] && echo true || echo false)"') ;;
	*) fail "jq の引数に渡す値が、件数の増えない値の一覧にない: $value" ;;
	esac
done <<<"$(bounded_values)"
echo 'PASS usage-wait jq: プロセス置換と、関数の引数の中のコマンド置換を使わず、jq の引数に渡す値は件数の増えない値に限る'

# ---- 準備。期限を過ぎた記録の N 件を、タスクのコメントの配列として 1 回の jq で作る。
expired_comments() { # 出力ファイル 件数
	jq -n --slurpfile p "$test_dir/comment-agent.json" --argjson n "$2" --argjson now "$now" --argjson t "$answer_t" '
		[range($n) as $i | ($t - 5000 - $i) as $c
			| $p[0] + {id: "exp\($i)", author_id: "orchestrator", created_at: ($c | todateiso8601),
				content: "使用率の答え: 待つ。答えた時刻: \($c | todateiso8601)。期限: \($now - 10 - ($i % 50) | todateiso8601)。スクワッド: squad-test。上限に近い枠: Claude 週 90%"}]' >"$1"
}
head -c 140000 /dev/zero | tr '\0' b >"$test_dir/bigfield.txt"

# ---- 答えの実行（T1）。期限を過ぎた記録が 800 件あるタスクがあっても、記録の配列を引数に渡さずに終える。
# 8 日以内に動いたタスクに、期限を過ぎた記録 800 件（記録の配列は 131,072 バイト以上）と効いている記録 1 件。
# 8 日より前に動いたマークのあるタスクに、期限を過ぎた記録 1 件。新しい答えは、効いている記録の答えと違う。
answer_setup near 7200
touch "$test_dir/apply-writes"
set_marked task-old:DEMO-1
set_all task-act:DEMO-2:$now task-old:DEMO-1:$((now - 9 * 86400))
expired_comments "$test_dir/comments-task-act.json" 800
add_task_comment comments-task-act.json agent orchestrator eff1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 5000)))"
add_task_comment comments-task-old.json agent orchestrator old1 $((answer_t - 4000)) "$(answer_line 待つ $((answer_t - 4000)) $((now - 100)))"
[[ $(wc -c <"$test_dir/comments-task-act.json") -gt 262144 ]]
run_answer planner 進める ans1
expect_status 0
new_line=$(answer_line 進める "$answer_t" $((now + 7200)))
expect_out "$new_line"
[[ $(posted_count) == 2 ]]
assert_jq -s --arg cancel "$(cancel_body eff1)" --arg line "$new_line" \
	'.[0] == {issue: "task-act", parent: "eff1", content: ($cancel + "\n")} and .[1] == {issue: "test-issue", parent: "ans1", content: ($line + "\n")}' "$test_dir/posted-comments.jsonl"
# マークのあるタスクのコメントを読み、効いている記録のないタスクのマークを外す。
assert_jq -s 'any(.[]; .[0] == "issue" and .[1] == "comment" and .[2] == "list" and .[3] == "task-old")' "$test_dir/calls.jsonl"
assert_jq -s 'any(.[]; .[2:4] == ["delete", "task-old"])' "$test_dir/metadata-calls.jsonl"
assert_no_rejected_calls
echo 'PASS usage-wait jq: answer は、期限を過ぎた記録が 800 件あるタスクでも、記録の配列を引数に渡さず、取り消し 1 件と新しい記録 1 件を書いて終了 0 になる'

# ---- 関数ごとの確認。スクリプトの本体を読み込み、multica と squad_cli_read を関数にして呼ぶ。
fn_reset() {
	: >"$test_dir/fn-posted"
	: >"$test_dir/fn-metadata"
	: >"$test_dir/fn-reads"
	: >"$test_dir/wakeup-deletes"
	mkdir -p "$test_dir/fn-work"
}
fn_run() { # 関数名 引数...。標準出力は out、標準エラーは err に置き、終了コードを status に入れる
	status=0
	fn_reset
	(
		source "$script"
		now=$now
		work_dir=$test_dir/fn-work
		multica() {
			case "$1 $2 $3" in
			'issue metadata set' | 'issue metadata delete') printf '%s\n' "$*" >>"$test_dir/fn-metadata" ;;
			'issue wakeup delete') printf '%s\n' "$5" >>"$test_dir/wakeup-deletes" ;;
			*) return 1 ;;
			esac
		}
		squad_cli_read() {
			case $1 in
			issue-comments) printf '%s\n' "$2" >>"$test_dir/fn-reads"; cat "$test_dir/comments-$2.json" ;;
			issue-comment-add) printf '%s %s\n' "$2" "$3" >>"$test_dir/fn-posted" ;;
			issue-wakeups) cat "$test_dir/fn-rules.json" ;;
			*) return 1 ;;
			esac
		}
		"$@"
	) >"$test_dir/out" 2>"$test_dir/err" || status=$?
}

# answer_records: 読まない 140,000 バイトの欄を持つタスクの配列を、標準入力で読み、そのタスクのコメントを 1 回読んで記録を返す。
expired_comments "$test_dir/comments-task-act.json" 1
tasks=$(jq -c --rawfile big "$test_dir/bigfield.txt" -n '[{id: "task-act", identifier: "DEMO-2", pad: $big}]')
fn_run answer_records "$tasks" squad-test orchestrator
expect_status 0
[[ $(<"$test_dir/fn-reads") == task-act ]]
assert_jq -e 'length == 1 and .[0].task == "task-act" and .[0].identifier == "DEMO-2" and .[0].cancelled == false' "$test_dir/out"
assert_no_rejected_calls
echo 'PASS usage-wait jq: answer_records は、140,000 バイトの読まない欄があるタスクの配列でも、タスクのコメントを 1 回読んで記録を返す'

# answer_tidy: マークのあるタスクの一覧の要素に 140,000 バイトの読まない欄があり、記録は 800 件の期限を過ぎた記録と、別のタスクの効いている 2 件。
# 古い方の記録を 1 件取り消し、期限を過ぎた記録だけのタスクのマークを外す。
expired_comments "$test_dir/comments-task-act.json" 800
records=$(jq -c --slurpfile c "$test_dir/comments-task-act.json" -n --argjson now "$now" --argjson t "$answer_t" '
	[$c[0][] | {task: "task-act", identifier: "DEMO-2", comment: .id, parent: .id, created: (.created_at | fromdateiso8601), answer: "待つ",
		answered: (.created_at | fromdateiso8601), expiry: ($now - 10), carried: false, cancelled: false}]
	+ [range(2) as $i | {task: "task-b", identifier: "DEMO-3", comment: "b\($i)", parent: "b\($i)", created: ($t - 2000 + $i), answer: "待つ",
		answered: ($t - 2000 + $i), expiry: ($now + 5000), carried: false, cancelled: false}]')
marked=$(jq -c --rawfile big "$test_dir/bigfield.txt" -n '[{id: "task-act", identifier: "DEMO-2", pad: $big}, {id: "task-b", identifier: "DEMO-3", pad: $big}]')
[[ ${#records} -gt 131072 && ${#marked} -gt 131072 ]]
printf '%s\n' "$marked" >"$test_dir/fn-marked.json"
status=0
fn_reset
(
	source "$script"
	now=$now
	work_dir=$test_dir/fn-work
	answer_marked_tasks() { cat "$test_dir/fn-marked.json"; }
	multica() { printf '%s\n' "$*" >>"$test_dir/fn-metadata"; }
	squad_cli_read() {
		case $1 in
		issue-comments) printf '%s\n' "$2" >>"$test_dir/fn-reads"; cat "$test_dir/comments-$2.json" ;;
		issue-comment-add) printf '%s %s\n' "$2" "$3" >>"$test_dir/fn-posted" ;;
		*) return 1 ;;
		esac
	}
	answer_tidy squad-test orchestrator "$records"
) >"$test_dir/out" 2>"$test_dir/err" || status=$?
expect_status 0
[[ $(<"$test_dir/fn-posted") == "task-b b0" ]]
[[ $(<"$test_dir/fn-metadata") == 'issue metadata delete task-act --key usage_answer_squad --output json' ]]
assert_no_rejected_calls
echo 'PASS usage-wait jq: answer_tidy は、読まない欄が大きいマークの一覧と 800 件の記録でも、古い記録を 1 件取り消し、期限を過ぎた記録だけのタスクのマークを外す'

# clear_wakeups（終了 0 と 4 の前）と wait_or_exceed（終了 3）: 対象の起こしの配列が 131,072 バイト以上。
jq -n --argjson now "$now" '[range(1700) as $i | {id: "wakeup-\($i + 100000000000)", enabled: true, agent_id: "orchestrator",
	instruction: "使用率の待ちの起こしで起きました。\n工程: planner\n再開の時刻: \($now + 5000 + $i | todateiso8601)"}]' >"$test_dir/fn-rules.json"
[[ $(wc -c <"$test_dir/fn-rules.json") -gt 131072 ]]
fn_run clear_wakeups test-issue planner orchestrator ''
expect_status 0
[[ $(wc -l <"$test_dir/wakeup-deletes" | tr -d ' ') == 1700 ]]
status=0
fn_reset
(
	source "$script"
	now=$now
	work_dir=$test_dir/fn-work
	record_loaded=1
	record_latest=
	pick_comments='[]'
	multica() { [[ "$1 $2 $3" == 'issue wakeup delete' ]] && printf '%s\n' "$5" >>"$test_dir/wakeup-deletes"; }
	squad_cli_read() { [[ $1 == issue-wakeups ]] && cat "$test_dir/fn-rules.json"; }
	wait_or_exceed test-issue planner orchestrator '' $((now + 7200)) '上限に近い枠: Claude 週 90%'
) >"$test_dir/out" 2>"$test_dir/err" || status=$?
expect_status 3
[[ $(wc -l <"$test_dir/wakeup-deletes" | tr -d ' ') == 1699 ]]
! grep -qxF 'wakeup-100000000000' "$test_dir/wakeup-deletes"
assert_no_rejected_calls
echo 'PASS usage-wait jq: clear_wakeups は 1,700 件の対象の起こしをすべて消し、wait_or_exceed は使う 1 件を残して 1,699 件を消す'
