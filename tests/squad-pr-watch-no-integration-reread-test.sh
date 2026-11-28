#!/usr/bin/env bash
# 連携なしの PR の unlinked-check のうち、書く直前の読み直しと、確認した回より後のマージの依頼を確認する。
# 実際のタスク・PR・ホストの記録には触れない。準備は pr-watch-no-integration-lib.sh に置く。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/pr-watch-no-integration-lib.sh"

# 書き込み直前に規則が入れ替わったら、古い規則では done・マージ後の知らせ・期限の知らせのどれも書かない。
for write in done not-done end; do
	unlinked_scene record "$(stamp -$((71 * 3600 + 60)))"
	if [[ $write != end ]]; then update_pr '.state = "MERGED"'; fi
	if [[ $write == not-done ]]; then same_pr_round; fi
	jq --arg created "$(stamp -3600)" '.[0] += {id:"replacement",created_at:$created}' \
		"$test_dir/rules.json" >"$test_dir/rules-on-reread.json"
	unlinked_run
	((unlinked_status == 0))
	[[ $(done_calls) == '[]' ]]
	assert_jq -s "$not_done_filter | length == 0" "$test_dir/posted.jsonl"
	no_notice
	assert_jq 'map(.id) == ["replacement"]' "$test_dir/rules.json"
	assert_jq -s '[.[] | select(.[0:3] == ["issue","wakeup","list"])] | length == 2' "$test_dir/calls.jsonl"
	if [[ $write == end ]]; then
		unlinked_run
		((unlinked_status == 0))
		no_notice
	fi
done
echo 'PASS no-integration: 書く直前に規則が入れ替わったら何も書かず、新しい規則の時刻を次の確認で使う'

# done を書いたあとに新しい規則が入っても、停止でその規則を消さない。
unlinked_scene record
update_pr '.state = "MERGED"'
jq '. + [.[0] + {id:"replacement"}]' "$test_dir/rules.json" >"$test_dir/rules-after-status.json"
unlinked_run
((unlinked_status == 0))
assert_jq '.status == "done"' "$test_dir/task.json"
assert_jq 'map(.id) == ["replacement"]' "$test_dir/rules.json"
echo 'PASS no-integration: done を書いたあとの停止では、確認に使った一覧の規則だけを消す'

# 規則の作り手が人間でも、照合がすべて合えば done にする。作り手は信頼の根拠にしない。
unlinked_scene record
jq '.[0] += {created_by:"human-1", created_by_name:"Owner", created_by_agent:false}' "$test_dir/rules.json" >"$test_dir/updated.json"
mv "$test_dir/updated.json" "$test_dir/rules.json"
update_pr '.state = "MERGED"'
unlinked_run
((unlinked_status == 0))
assert_jq '.status == "done"' "$test_dir/task.json"
rule_gone
echo 'PASS no-integration: 規則の作り手が人間でも、照合が合えば done にする'

# done の照合の 5。確認した回より後に、その回の確認するコミットを指すマージの依頼がなければ、マージされても done にしない。
# レビュー中に人間が手でマージした PR は、依頼の前なので、done にせず、人間に知らせる。
no_request() { drop_request; }
human_request() { drop_request; add_comment merge-x member human-1 "$(merge_request_body)"; }
rogue_request() { drop_request; add_comment merge-x agent rogue "$(merge_request_body)"; }
other_head_request() { drop_request; add_comment merge-x agent orchestrator "$(merge_request_body 1111111111111111111111111111111111111111)"; }
fenced_request() { drop_request; add_comment merge-x agent orchestrator $'```\n'"$(merge_request_body)"$'\n```'; }
result_request() { drop_request; add_comment merge-x agent orchestrator $'/note\n返事の回: round-1\n'"$(merge_request_body)"; }
before_round_request() {
	drop_request
	jq --slurpfile base "$test_dir/comment-prototype.json" --arg content "$(merge_request_body)" \
		'[$base[0] + {id: "merge-before", author_type: "agent", author_id: "orchestrator", content: $content}] + .' \
		"$test_dir/comments.json" >"$test_dir/changed.json"
	mv "$test_dir/changed.json" "$test_dir/comments.json"
}
prepare_extra=no_request merged_refuses 'レビュー中（マージの依頼の前）に人間がマージ'
grep -q '確認した回より後に、確認するコミット（abcdef0）のマージの依頼がない' "$test_dir/err"
prepare_extra=human_request merged_refuses 'マージの依頼が人間のコメント'
prepare_extra=rogue_request merged_refuses 'マージの依頼が名簿の外のエージェントのコメント'
prepare_extra=other_head_request merged_refuses 'マージの依頼が回のコミットと別の head'
prepare_extra=fenced_request merged_refuses 'マージの依頼がコードの囲みの中'
prepare_extra=result_request merged_refuses 'マージの依頼が結果のコメント'
prepare_extra=before_round_request merged_refuses 'マージの依頼が回より前（前の回の依頼）'
unset prepare_extra
echo 'PASS no-integration: 確認した回より後のマージの依頼がなければ、マージされても done にせず、理由と知らせを出して止める'

other_pr_request() { drop_request; add_comment merge-x agent orchestrator "$(merge_request_body "$merge_head" round-1 "$other")"; }
missing_pr_request() { drop_request; add_comment merge-x agent orchestrator "マージの依頼: $merge_head"$'\n前の回: round-1'; }
two_pr_request() { drop_request; add_comment merge-x agent orchestrator "$(merge_request_body)"$'\nマージする PR: '"$pr"; }
two_head_request() { drop_request; add_comment merge-x agent orchestrator "$(merge_request_body)"$'\nマージの依頼: '"$merge_head"; }
prepare_extra=other_pr_request merged_refuses '依頼の PR だけが規則と違う'
prepare_extra=missing_pr_request merged_refuses '依頼の PR の行がない'
prepare_extra=two_pr_request merged_refuses '依頼の PR の行が 2 つ'
prepare_extra=two_head_request merged_refuses '依頼の head の行が 2 つ'
echo 'PASS no-integration: 依頼の PR・head の行が照合に合わなければ、done にせず知らせる'

# 依頼として読むもの。名簿のリーダーのコメントと、回で待つ役の制御記録。回の確認するコミットは、接頭辞でも 40 桁でもよい。
for case in leader control full; do
	unlinked_scene record
	case $case in
	control)
		drop_request
		add_comment decide-1 agent monitor $'/note\n返事の待ち: 次の依頼を決めます'
		add_comment merge-x agent monitor "$(merge_request_body)" ;;
	full)
		jq --arg commit "$merge_head" 'map(if .id == "round-1" then .content |= sub("確認するコミット: abcdef0"; "確認するコミット: " + $commit) else . end)' \
			"$test_dir/comments.json" >"$test_dir/changed.json"
		mv "$test_dir/changed.json" "$test_dir/comments.json" ;;
	esac
	update_pr '.state = "MERGED"'
	unlinked_run
	((unlinked_status == 0)) || { echo "FAIL ${case}: 終了コード $unlinked_status" >&2; cat "$test_dir/err" >&2; exit 1; }
	assert_jq '.status == "done"' "$test_dir/task.json" || { echo "FAIL ${case}: done でない" >&2; cat "$test_dir/err" >&2; exit 1; }
	rule_gone
	no_posts
done
echo 'PASS no-integration: リーダーの依頼と、待つ役の制御記録の依頼で done にする。回のコミットは 40 桁でもよい'

# 依頼の候補を読めないとき（引用）は、done にも知らせにもせず、規則を残して 1 で終わる。読めるようになれば、次の確認で決める。
unlinked_scene record
drop_request
add_comment merge-x agent orchestrator $'> マージの依頼: '"$merge_head"$'\n> 前の回: round-1'
update_pr '.state = "MERGED"'
unlinked_run
((unlinked_status == 1))
grep -q '照合できませんでした' "$test_dir/err"
[[ $(done_calls) == '[]' ]]
rule_kept
no_posts
drop_request
jq 'map(select(.id != "merge-x"))' "$test_dir/comments.json" >"$test_dir/changed.json"
mv "$test_dir/changed.json" "$test_dir/comments.json"
add_comment merge-1 agent orchestrator "$(merge_request_body)"
unlinked_run
((unlinked_status == 0))
assert_jq '.status == "done"' "$test_dir/task.json"
echo 'PASS no-integration: マージの依頼の候補を読めないときは、規則を残して 1 で終わり、読めれば次の確認で決める'

upper=$(tr '[:lower:]' '[:upper:]' <<<"$merge_head")
for candidate in alone with-request; do
	unlinked_scene record
	if [[ $candidate == alone ]]; then drop_request; fi
	add_comment merge-x agent orchestrator "> $(merge_request_body "$upper")"
	update_pr '.state = "MERGED"'
	unlinked_run
	((unlinked_status == 1)) || { echo "FAIL $candidate: 終了コード $unlinked_status" >&2; cat "$test_dir/err" >&2; exit 1; }
	grep -Fq '制御記録を読めない（merge-x: 引用）' "$test_dir/err"
	[[ $(done_calls) == '[]' ]]
	assert_jq '.status == "in_review"' "$test_dir/task.json"
	rule_kept
	no_posts
done
echo 'PASS no-integration: 大文字 SHA の読めない候補は、読める依頼の有無によらず書き込まず規則を残す'

# 見張りの終わりの知らせは、照合の 1 から 3 だけで書く。マージの依頼は要らない。
unlinked_scene record "$(stamp -$((71 * 3600 + 60)))"
drop_request
unlinked_run
((unlinked_status == 0))
assert_jq -s "$notice_filter | length == 1" "$test_dir/posted.jsonl"
echo 'PASS no-integration: 終わりの知らせは、マージの依頼がなくても書く'

# 名簿は照合の 1 回だけ読み、書く直前の読み直しでは読み直さない。
unlinked_scene record
update_pr '.state = "MERGED"'
unlinked_run
((unlinked_status == 0))
assert_jq -s '[.[] | select(.[0:3] == ["squad","member","list"])] | length == 1' "$test_dir/calls.jsonl"
assert_jq -s '[.[] | select(.[0:3] == ["issue","wakeup","list"])] | length == 2' "$test_dir/calls.jsonl"
echo 'PASS no-integration: done の前の読み直しで、名簿は読み直さない'

# 照合のあと書く前にデータが変わったら、古い判定では何も書かず、規則を残して 0 で終わる。次の確認で決め直す。
reread_add() { # ID 作者の種類 作者の ID 本文（読み直しのときに増えるコメント）
	jq --slurpfile base "$test_dir/comment-prototype.json" --arg id "$1" --arg type "$2" --arg author "$3" --arg content "$4" \
		'. + [$base[0] + {id: $id, author_type: $type, author_id: $author, content: $content}]' "$test_dir/comments.json" >"$test_dir/comments-on-reread.json"
}
reread_drop_request() { jq 'map(select(.id != "merge-1"))' "$test_dir/comments.json" >"$test_dir/comments-on-reread.json"; }
changed_window() { # 名前
	((unlinked_status == 0)) || { echo "FAIL $1: 終了コード $unlinked_status" >&2; cat "$test_dir/err" >&2; exit 1; }
	[[ $(done_calls) == '[]' ]] || { echo "FAIL $1: done にした" >&2; exit 1; }
	assert_jq '.status == "in_review"' "$test_dir/task.json"
	assert_jq -s "$not_done_filter | length == 0" "$test_dir/posted.jsonl"
	no_notice
	rule_kept
	assert_jq -s '[.[] | select(.[0:3] == ["issue","wakeup","list"])] | length == 2' "$test_dir/calls.jsonl"
	grep -q '書かずに規則を残します' "$test_dir/err" || { echo "FAIL $1: 理由を出さない" >&2; cat "$test_dir/err" >&2; exit 1; }
}
# done: 別の PR の回が書かれる。次の確認は、確認した回が今の回でないので、知らせを 1 回だけ書く。
unlinked_scene record
update_pr '.state = "MERGED"'
reread_add round-2 agent orchestrator "$(round_body "$other")"
unlinked_run
changed_window 'done: 別の PR の回'
rm -f "$test_dir/rules-read"
unlinked_run
((unlinked_status == 0))
[[ $(done_calls) == '[]' ]]
assert_jq -s "$not_done_filter | length == 1" "$test_dir/posted.jsonl"
rule_gone
# done: マージの依頼がコメントから消える。次の確認で知らせを書く。
unlinked_scene record
update_pr '.state = "MERGED"'
reread_drop_request
unlinked_run
changed_window 'done: 依頼が消えた'
rm -f "$test_dir/rules-read"
unlinked_run
assert_jq -s "$not_done_filter | length == 1" "$test_dir/posted.jsonl"
# done: metadata の PR とマークが別の PR に変わる。
unlinked_scene record
update_pr '.state = "MERGED"'
jq ".metadata.pr_url = \"$other\" | .metadata.pr_link_pending = \"$other\" | .metadata.pr_link_no_integration = \"$other\"" "$test_dir/task.json" >"$test_dir/task-on-reread.json"
unlinked_run
changed_window 'done: metadata が変わった'
# done にしなかったときの知らせ: 依頼が書かれて照合が合う。次の確認で done にする。
unlinked_scene record
no_request
update_pr '.state = "MERGED"'
reread_add merge-x agent orchestrator "$(merge_request_body)"
unlinked_run
changed_window 'not-done: 依頼が書かれた'
rm -f "$test_dir/rules-read"
unlinked_run
((unlinked_status == 0))
assert_jq '.status == "done"' "$test_dir/task.json"
no_posts
# done にしなかったときの知らせ: 理由が変わる（別の PR の回）。次の確認で、新しい理由の知らせを 1 回だけ書く。
unlinked_scene record
no_request
update_pr '.state = "MERGED"'
reread_add round-2 agent orchestrator "$(round_body "$pr")"
unlinked_run
changed_window 'not-done: 回が変わった'
rm -f "$test_dir/rules-read"
unlinked_run
assert_jq -s "$not_done_filter"' | length == 1 and (.[0].body | contains("確認した回（round-1）が今の回（round-2）と違う"))' "$test_dir/posted.jsonl"
# 終わりの知らせ: 別の PR の回が書かれる。次の確認は照合が合わないので、書かない。
unlinked_scene record "$(stamp -$((71 * 3600 + 60)))"
reread_add round-2 agent orchestrator "$(round_body "$other")"
unlinked_run
changed_window 'end: 別の PR の回'
rm -f "$test_dir/rules-read"
unlinked_run
((unlinked_status == 0))
no_notice
echo 'PASS no-integration: 照合のあと書く前に回・依頼・metadata が変わったら、何も書かず規則を残し、次の確認で決め直す'

# 書く直前の読み直しで、コメントを読めなければ、何も書かず規則を残して 1 で終わる。読めるようになれば決め直す。
for write in done not-done end; do
	case $write in
	end) unlinked_scene record "$(stamp -$((71 * 3600 + 60)))" ;;
	*) unlinked_scene record; update_pr '.state = "MERGED"' ;;
	esac
	if [[ $write == not-done ]]; then no_request; fi
	echo 'issue comment list' >"$test_dir/fail-on-reread"
	unlinked_run
	((unlinked_status == 1)) || { echo "FAIL ${write}: 終了コード $unlinked_status" >&2; cat "$test_dir/err" >&2; exit 1; }
	grep -q '書く直前の読み直しで' "$test_dir/err"
	[[ $(done_calls) == '[]' ]]
	assert_jq '.status == "in_review"' "$test_dir/task.json"
	assert_jq -s "$not_done_filter | length == 0" "$test_dir/posted.jsonl"
	no_notice
	rule_kept
	rm -f "$test_dir/fail" "$test_dir/rules-read"
	unlinked_run
	((unlinked_status == 0))
	case $write in
	done) assert_jq '.status == "done"' "$test_dir/task.json" ;;
	not-done) assert_jq -s "$not_done_filter | length == 1" "$test_dir/posted.jsonl" ;;
	end) assert_jq -s "$notice_filter | length == 1" "$test_dir/posted.jsonl" ;;
	esac
done
echo 'PASS no-integration: 書く直前の読み直しで読めないものがあれば、何も書かず規則を残して 1 で終わる'

# 照合が合わないときは、71 時間を過ぎても終わりの知らせを書かない。標準エラーに理由を出し、CI とコンフリクトの行は今のままにする。
for case in line round latest; do
	case $case in
	line) lines='確認した回: round-1' ;;
	round) lines=$(rule_lines "$pr" other-round) ;;
	latest) lines=$(rule_lines) ;;
	esac
	unlinked_scene record "$(stamp -$((71 * 3600 + 60)))" "$lines"
	if [[ $case == round ]]; then other_round; fi
	if [[ $case == latest ]]; then same_pr_round; fi
	unlinked_run
	((unlinked_status == 0))
	no_notice
	[[ $(grep -c '知らせを書きません' "$test_dir/err") == 1 ]]
	[[ $(<"$test_dir/out") == $'/note'* ]]
done
echo 'PASS no-integration: 照合が合わなければ 71 時間を過ぎても知らせず、理由を標準エラーに出す'

# マークの片方を書けなかった PR は、link-check で書き直したあとにマージされれば、unlinked-check で done になる。
for key in pr_link_pending pr_link_no_integration; do
	reset_ni
	make_record
	touch "$test_dir/fail-set-$key"
	check_ni "紐付け: 紐付いていない pr: $pr"
	rm -f "$test_dir/fail-set-$key"
	check_ni "紐付け: 紐付いていない pr: $pr 連携: なし"
	both_marks "$pr"
	unlinked_prepare
	update_pr '.state = "MERGED"'
	unlinked_run
	((unlinked_status == 0))
	assert_jq '.status == "done"' "$test_dir/task.json"
	rule_gone
done
echo 'PASS no-integration: マークの片方を書き直したあと、マージされると done になる'

# 照合のあと書く前に、同じ PR で新しい回が書かれたら、古い回の依頼で done にしない。次の確認で、知らせを 1 回だけ書く。
unlinked_scene record
update_pr '.state = "MERGED"'
reread_add round-2 agent orchestrator "$(round_body "$pr")"
unlinked_run
changed_window 'done: 同じ PR の新しい回'
rm -f "$test_dir/rules-read"
unlinked_run
((unlinked_status == 0))
[[ $(done_calls) == '[]' ]]
assert_jq -s "$not_done_filter"' | length == 1 and (.[0].body | contains("確認した回（round-1）が今の回（round-2）と違う"))' "$test_dir/posted.jsonl"
rule_gone
echo 'PASS no-integration: 照合のあとに同じ PR の新しい回が書かれたら、古い回で done にせず、次の確認で知らせる'

# 照合のあと書く前に、タスクが取り消されるか作業中へ戻ったら、done・マージ後の知らせ・終わりの知らせのどれも書かず、規則を残して 0 で終わる。
state_window() { # 名前 書くもの（done・not-done・end） 変わったあとの状態（cancelled・in_progress）
	local name=$1 write=$2 state=$3 update
	case $write in
	end) unlinked_scene record "$(stamp -$((71 * 3600 + 60)))" ;;
	*) unlinked_scene record; update_pr '.state = "MERGED"' ;;
	esac
	if [[ $write == not-done ]]; then no_request; fi
	update=".status = \"$state\""
	if [[ $state == cancelled ]]; then update+=' | .status_category = "cancelled"'; fi
	jq "$update" "$test_dir/task.json" >"$test_dir/task-on-reread.json"
	unlinked_run
	((unlinked_status == 0)) || { echo "FAIL $name: 終了コード $unlinked_status" >&2; cat "$test_dir/err" >&2; exit 1; }
	[[ $(done_calls) == '[]' ]] || { echo "FAIL $name: done にした" >&2; exit 1; }
	assert_jq ".status == \"$state\"" "$test_dir/task.json"
	assert_jq -s "$not_done_filter | length == 0" "$test_dir/posted.jsonl"
	no_notice
	rule_kept
	grep -q '書かずに規則を残します' "$test_dir/err" || { echo "FAIL $name: 理由を出さない" >&2; cat "$test_dir/err" >&2; exit 1; }
	# 次の確認は、取り消されたタスクと、マージ待ちでなくなったタスクを止める。マージ済みの PR で作業中のタスクは、次の確認で照合し直す。
	if [[ $state == cancelled || $write == end ]]; then
		unlinked_run
		((unlinked_status == 0))
		[[ $(done_calls) == '[]' ]]
		assert_jq -s "$not_done_filter | length == 0" "$test_dir/posted.jsonl"
		no_notice
		rule_gone
	fi
}
for write in done not-done end; do
	for state in cancelled in_progress; do
		state_window "$write → $state" "$write" "$state"
	done
done
echo 'PASS no-integration: 照合のあとに取り消されるか作業中へ戻ったタスクには、done も知らせも書かない'
