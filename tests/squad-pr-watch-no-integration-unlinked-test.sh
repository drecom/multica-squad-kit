#!/usr/bin/env bash
# 連携なしの PR の unlinked-check のうち、マージと閉じたときの扱い、done の照合、マージ後の知らせ、見張りの終わりの知らせ、紐付けの知らせを確認する。
# 実際のタスク・PR・ホストの記録には触れない。準備は pr-watch-no-integration-lib.sh に置く。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/pr-watch-no-integration-lib.sh"


# 連携なしのマークが同じ PR のままマージされたら、タスクを done にし、見張りを止める。
unlinked_scene record
update_pr '.state = "MERGED"'
unlinked_run
((unlinked_status == 0))
[[ $(done_calls | jq -c 'map(.[0:5])') == '[["issue","status","test-issue","done","--no-start"]]' ]]
assert_jq '.status == "done"' "$test_dir/task.json"
rule_gone
no_posts
echo 'PASS no-integration: unlinked-check は、連携なしのマークの PR がマージされたら done にして止める'

# 照合に必要な読み取りが失敗しても、規則を残す。次の確認で読めれば同じ規則で done にする。
for query in 'issue comment list' 'squad list --output' 'squad member list' 'agent get monitor'; do
	unlinked_scene record
	update_pr '.state = "MERGED"'
	printf '%s\n' "$query" >"$test_dir/fail"
	unlinked_run
	((unlinked_status == 1))
	grep -qF '照合できませんでした' "$test_dir/err"
	[[ $(done_calls) == '[]' ]]
	assert_jq '.status == "in_review"' "$test_dir/task.json"
	rule_kept
	no_posts
	rm -f "$test_dir/fail"
	unlinked_run
	((unlinked_status == 0))
	assert_jq '.status == "done"' "$test_dir/task.json"
	rule_gone
	no_posts
done
echo 'PASS no-integration: コメントや名簿を読めないときは規則を残し、読めるようになれば done にする'

# 終わりの知らせでも、照合に必要な名簿を読めるまで知らせを待つ。
unlinked_scene record "$(stamp -$((71 * 3600 + 60)))"
echo 'squad member list' >"$test_dir/fail"
unlinked_run
((unlinked_status == 1))
grep -qF '名簿を読めない' "$test_dir/err"
rule_kept
no_notice
rm -f "$test_dir/fail"
unlinked_run
((unlinked_status == 0))
rule_kept
assert_jq -s "$notice_filter | length == 1" "$test_dir/posted.jsonl"
echo 'PASS no-integration: 名簿を読めるまで見張りの終わりの知らせを待つ'

# マークがない（または別の PR の）マージは、今と同じく done にせず止める。
for kind in none other; do
	unlinked_scene record
	if [[ $kind == none ]]; then
		update_task 'del(.metadata.pr_link_pending, .metadata.pr_link_no_integration)'
	else
		set_marks "$other"
	fi
	update_pr '.state = "MERGED"'
	unlinked_run
	((unlinked_status == 0))
	[[ $(done_calls) == '[]' ]]
	assert_jq '.status == "in_review"' "$test_dir/task.json"
	rule_gone
done
echo 'PASS no-integration: マークがない・別の PR のマージは done にしない'

# 閉じた PR は、マークがあっても done にしない。見張りは止める。
unlinked_scene record
update_pr '.state = "CLOSED"'
unlinked_run
((unlinked_status == 0))
[[ $(done_calls) == '[]' ]]
assert_jq '.status == "in_review"' "$test_dir/task.json"
rule_gone
echo 'PASS no-integration: 閉じた PR は done にしない'

# done にできなかったときは、規則を残し、理由を標準エラーに出して 1 で終わる。
unlinked_scene record
update_pr '.state = "MERGED"'
: >"$test_dir/fail-status"
unlinked_run
((unlinked_status == 1))
[[ $(<"$test_dir/err") == *'done にできませんでした'* ]]
rule_kept
assert_jq '.status == "in_review"' "$test_dir/task.json"
echo 'PASS no-integration: done にできないときは規則を残して 1 で終わる'

# 作成から 71 時間を過ぎたら、終わりの知らせを 1 回だけ書く。呼ぶ人間をメンションする。
unlinked_scene record "$(stamp -$((71 * 3600 + 60)))"
unlinked_run
((unlinked_status == 0))
assert_jq -s "$notice_filter"' | length == 1 and (.[0].args | index("--parent") as $i | .[$i + 1] == "ci-thread")
	and (.[0].body | rtrimstr("\n") | split("\n") | length == 2)
	and (.[0].body | split("\n")[0] | endswith("に終わります。そのあとにマージしたときは、タスクを `done` にしてください。マージせずに閉じたときは、`done` にしません。PR: `'"$pr"'`"))
	and (.[0].body | split("\n")[1] == "[@Owner](mention://member/human-1)")' "$test_dir/posted.jsonl"
rule_kept
unlinked_run
((unlinked_status == 0))
assert_jq -s "$notice_filter | length == 1" "$test_dir/posted.jsonl"
echo 'PASS no-integration: 71 時間を過ぎた連携なしのマージ待ちは、終わりの知らせを 1 回だけ書く'

# 終了時刻は、規則の作成時刻の 72 時間後の UTC にする。
created=$(stamp -$((71 * 3600 + 60)))
unlinked_scene record "$created"
unlinked_run
expected_end=$(python3 -c 'import datetime, sys
print((datetime.datetime.strptime(sys.argv[1], "%Y-%m-%dT%H:%M:%SZ") + datetime.timedelta(hours=72)).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$created")
assert_jq -s --arg end "$expected_end" "$notice_filter"' | .[0].body | split("\n")[0] | contains("見張りが、" + $end + " に終わります")' "$test_dir/posted.jsonl"
echo 'PASS no-integration: 終わりの時刻は規則の作成の 72 時間後'

# 71 時間に満ちないとき、マークがないとき、記録の別の PR のときは書かない。
unlinked_scene record "$(stamp -$((71 * 3600 - 600)))"
unlinked_run
((unlinked_status == 0))
no_notice
unlinked_scene record
unlinked_run
no_notice
unlinked_scene record "$(stamp -$((71 * 3600 + 60)))"
update_task 'del(.metadata.pr_link_pending, .metadata.pr_link_no_integration)'
unlinked_run
no_notice
unlinked_scene record "$(stamp -$((71 * 3600 + 60)))"
set_marks "$other"
unlinked_run
no_notice
echo 'PASS no-integration: 71 時間に満ちないとき・マークがないとき・別の PR のときは知らせない'

# 呼ぶ人間を決められないときは、メンションの行を省いて書き、理由を標準エラーに出して 1 で終わる。
unlinked_scene record "$(stamp -$((71 * 3600 + 60)))"
: >"$test_dir/fail-members"
unlinked_run
((unlinked_status == 1))
assert_jq -s "$notice_filter"' | length == 1 and (.[0].body | contains("mention://") | not)' "$test_dir/posted.jsonl"
[[ $(<"$test_dir/err") == *'メンションを省きました'* ]]
echo 'PASS no-integration: 呼ぶ人間を決められないときは、メンションなしで書いて 1 で終わる'

merged_refuses '見張る PR が同じリポジトリの別の PR' "$(rule_lines "$other")"
merged_refuses '見張る PR の行がない' $'確認した回: round-1'
merged_refuses '見張る PR の行が 2 つ' "$(rule_lines)"$'\n見張る PR: '"$pr"
merged_refuses '確認した回の行がない' "見張る PR: $pr"
merged_refuses '確認した回の行が 2 つ' "$(rule_lines)"$'\n確認した回: round-1'
merged_refuses '見張る PR が URL でない' "$(rule_lines 'https://example.com/x')"
merged_refuses '回が存在しない' "$(rule_lines "$pr" no-such-round)"
prepare_extra=other_round merged_refuses '回の対象の PR が見張る PR と違う' "$(rule_lines "$pr" other-round)"
human_round() { add_comment human-round member human-1 "$(round_body "$pr")"; }
prepare_extra=human_round merged_refuses '回が人間のコメント' "$(rule_lines "$pr" human-round)"
rogue_round() { add_comment rogue-round agent rogue "$(round_body "$pr")"; }
prepare_extra=rogue_round merged_refuses '回が名簿の外のエージェントのコメント' "$(rule_lines "$pr" rogue-round)"
result_round() { add_comment result-round agent orchestrator "$(round_body "$pr")"$'\n返事の回: round-1'; }
prepare_extra=result_round merged_refuses '回が結果のコメント' "$(rule_lines "$pr" result-round)"
# 回のコメントの `対象の PR:` が囲みの中・引用・項目・字下げにしかないとき、または囲みの外が 2 つのときは、PR がマージされても done にしない。
for attack in fence tilde quote item indent two-outside; do
	attack_round() {
		local head=$'確認するコミット: abcdef0\n返事を待つ役: [@demo-monitor-test](mention://agent/monitor)\n観点: code-reviewer（テスト）' body
		case $attack in
		fence) body="$head"$'\n```\n対象の PR: '"$pr"$'\n```' ;;
		tilde) body="$head"$'\n~~~\n対象の PR: '"$pr"$'\n~~~' ;;
		quote) body="$head"$'\n> 対象の PR: '"$pr" ;;
		item) body="$head"$'\n- 対象の PR: '"$pr" ;;
		indent) body="$head"$'\n  対象の PR: '"$pr" ;;
		two-outside) body="$head"$'\n対象の PR: '"$pr"$'\n対象の PR: '"$other" ;;
		esac
		# 回（round-1）の本文だけを差し替える。マージの依頼・規則の 2 行・metadata は、done になる場面のままにする。
		jq --arg body "$body" 'map(if .id == "round-1" then .content = $body else . end)' "$test_dir/comments.json" >"$test_dir/changed.json"
		mv "$test_dir/changed.json" "$test_dir/comments.json"
	}
	prepare_extra=attack_round merged_refuses "回の対象の PR が囲み・引用・項目・字下げか 2 つ: $attack"
done
# 登録のあとに pr_url と連携なしのマークを別のマージ済みの PR に書き換えても、回の PR と合わないので done にしない。
swapped_marks() { update_task ".metadata.pr_url = \"$other\" | .metadata.pr_link_pending = \"$other\" | .metadata.pr_link_no_integration = \"$other\""; }
prepare_extra=swapped_marks merged_refuses 'pr_url とマークが別の PR に変わった'
edit_round_pr() {
	jq --arg content "$(round_body "$other")" 'map(if .id == "round-1" then .content = $content else . end)' \
		"$test_dir/comments.json" >"$test_dir/changed.json"
	mv "$test_dir/changed.json" "$test_dir/comments.json"
}
prepare_extra=edit_round_pr merged_refuses '登録した回のコメントの対象 PR が編集された'
unset prepare_extra
# タスクの担当がスクワッドから変わったときは、名簿を読めて作者を決められないので「合わない」とし、done にせず知らせを 1 回書いて規則を消す。
change_assignee() { update_task '.assignee_type = "agent" | .assignee_id = "orchestrator"'; }
prepare_extra=change_assignee merged_refuses 'タスクの担当がスクワッドから変わった'
unset prepare_extra
echo 'PASS no-integration: 規則の行・回・metadata のどれかが合わないマージは、done にせず、理由と知らせを出して止める'

prepare_extra=same_pr_round merged_refuses '同じ PR の新しい回の途中でマージ'
grep -q '確認した回（round-1）が今の回（round-2）と違う' "$test_dir/err"
unlinked_run
((unlinked_status == 0))
[[ $(done_calls) == '[]' ]]
assert_jq -s "$not_done_filter | length == 1" "$test_dir/posted.jsonl"
prepare_extra=other_round merged_refuses 'PR 差し替え後に規則と metadata とマークがすべて旧 PR に戻り、旧 PR がマージ'
grep -q '確認した回（round-1）が今の回（other-round）と違う' "$test_dir/err"
echo 'PASS no-integration: 同じ PR の再レビューや PR の差し替え後は、古い回で done にせず、人間に一度だけ知らせる'

# 差し替えた PR は OPEN のまま、旧 PR だけが MERGED になったときも done にしない。
unlinked_scene record
other_round
swapped_marks
mv "$test_dir/bin/gh" "$test_dir/bin/gh-base"
cat >"$test_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$PR_WATCH_TEST_DIR
if [[ "${1-} ${2-} ${3-} ${5-}" == 'pr view https://github.com/example/repo/pull/67 state,headRefOid,mergeable' ]]; then
	jq '.state = "MERGED"' "$dir/mergeable.json"
else
	exec "$dir/bin/gh-base" "$@"
fi
EOF
chmod +x "$test_dir/bin/gh"
unlinked_run
mv "$test_dir/bin/gh-base" "$test_dir/bin/gh"
((unlinked_status == 0))
[[ $(done_calls) == '[]' ]]
assert_jq '.status == "in_review"' "$test_dir/task.json"
assert_jq -s "$not_done_filter | length == 0" "$test_dir/posted.jsonl"
echo 'PASS no-integration: metadata が差し替え先を指したまま、旧 PR だけがマージされても done にしない'

unlinked_scene record
same_pr_round
update_pr '.state = "MERGED"'
: >"$test_dir/fail-post"
unlinked_run
((unlinked_status == 1))
rule_kept
no_posts
rm "$test_dir/fail-post"
unlinked_run
((unlinked_status == 0))
rule_gone
assert_jq -s "$not_done_filter | length == 1" "$test_dir/posted.jsonl"
echo 'PASS no-integration: done にしなかったときの知らせの投稿に失敗したら規則を残し、次の確認で一度だけ書く'

unlinked_scene record
same_pr_round
update_pr '.state = "MERGED"'
: >"$test_dir/fail-members"
unlinked_run
((unlinked_status == 1))
rule_gone
assert_jq -s "$not_done_filter"' | length == 1 and (.[0].body | contains("mention://") | not)' "$test_dir/posted.jsonl"
grep -q 'メンションを省きました' "$test_dir/err"
echo 'PASS no-integration: 呼ぶ人間を決められないときは、マージ後の知らせをメンションなしで書いて 1 で終わる'

unlinked_scene record
same_pr_round
update_pr '.state = "MERGED"'
touch "$test_dir/fail-notice-squad"
unlinked_run
((unlinked_status == 1))
rule_gone
assert_jq -s "$not_done_filter"' | length == 1 and (.[0].body | contains("mention://") | not)' "$test_dir/posted.jsonl"
grep -q 'メンションを省きました' "$test_dir/err"
echo 'PASS no-integration: 照合後に知らせの宛先のスクワッドを取得できなくても、マージ後の知らせをメンションなしで書く'

# 知らせ済みと読むのは、ci_watch_thread への名簿のエージェントの返信だけ。同じ 1 行目でも、人間・名簿の外のエージェント・別のコメントへの返信・返信でないコメントは、知らせを省かない。
not_done_first="連携なしのリポジトリの PR がマージされましたが、見張りはタスクを \`done\` にしませんでした（規則の確認した回（round-1）が今の回（round-2）と違う）。このタスクの成果をマージしたなら、タスクを \`done\` にしてください。PR: \`${pr}\`"
not_done_scene() {
	unlinked_scene record
	same_pr_round
	update_pr '.state = "MERGED"'
}
# 作者の種類・作者の ID・返信先（空なら返信でない）の組ごとに、知らせを書くか。
for who in 'member human-1 ci-thread' 'agent outsider ci-thread' 'agent orchestrator other-comment' 'agent monitor' 'agent orchestrator ci-thread' 'agent monitor ci-thread'; do
	read -r type author reply <<<"$who"
	not_done_scene
	reply_to=$reply add_comment existing-notice "$type" "$author" "$not_done_first"
	unlinked_run
	((unlinked_status == 0)) || { echo "FAIL 知らせ済み（$who）: 終了コード $unlinked_status" >&2; cat "$test_dir/err" >&2; exit 1; }
	rule_gone
	if [[ $reply == ci-thread && $author != outsider && $type == agent ]]; then
		no_posts
	else
		assert_jq -s "$not_done_filter | length == 1" "$test_dir/posted.jsonl"
	fi
done
echo 'PASS no-integration: マージ後の知らせは、ci_watch_thread への名簿のエージェントの返信だけを知らせ済みと読む'

# 見張りの終わりの知らせも、同じ判定で読む。
for who in 'member human-1 ci-thread' 'agent orchestrator other-comment' 'agent orchestrator ci-thread'; do
	created=$(stamp -$((71 * 3600 + 60)))
	read -r type author reply <<<"$who"
	unlinked_scene record "$created"
	end=$(python3 -c 'import datetime,sys;print((datetime.datetime.strptime(sys.argv[1],"%Y-%m-%dT%H:%M:%SZ")+datetime.timedelta(hours=72)).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$created")
	first_line="連携なしのリポジトリの PR のマージ待ちの見張りが、${end} に終わります。そのあとにマージしたときは、タスクを \`done\` にしてください。マージせずに閉じたときは、\`done\` にしません。PR: \`${pr}\`"
	reply_to=$reply add_comment existing-notice "$type" "$author" "$first_line"
	unlinked_run
	((unlinked_status == 0)) || { echo "FAIL 終わりの知らせ（$who）: 終了コード $unlinked_status" >&2; cat "$test_dir/err" >&2; exit 1; }
	if [[ $reply == ci-thread && $type == agent ]]; then
		no_notice
	else
		assert_jq -s "$notice_filter | length == 1" "$test_dir/posted.jsonl"
	fi
done
echo 'PASS no-integration: 見張りの終わりの知らせも、ci_watch_thread への名簿のエージェントの返信だけを知らせ済みと読む'

# unlinked_link_stop の知らせも同じ判定で読む。タイトルと判定の行が同じでも、人間・名簿の外・別のコメントへの返信は、知らせを省かない。
link_stop_scene() {
	unlinked_scene record
	update_task '.metadata.repository = "example/other"'
}
link_stop_scene
unlinked_run
((unlinked_status == 0))
link_stop_body=$(jq -rs '.[0].body | split("\n") | .[0:2] | join("\n")' "$test_dir/posted.jsonl")
[[ $link_stop_body == 'PR の URL を確認できませんでした。'$'\n''紐付け: '* ]]
rule_gone
for who in 'member human-1 ci-thread' 'agent outsider ci-thread' 'agent orchestrator ci-thread'; do
	read -r type author reply <<<"$who"
	link_stop_scene
	reply_to=$reply add_comment existing-notice "$type" "$author" "$link_stop_body"$'\n\nメンション'
	unlinked_run
	((unlinked_status == 0)) || { echo "FAIL 紐付けの知らせ（$who）: 終了コード $unlinked_status" >&2; cat "$test_dir/err" >&2; exit 1; }
	rule_gone
	if [[ $reply == ci-thread && $type == agent && $author != outsider ]]; then
		no_posts
	else
		assert_jq -s 'map(select(.body | startswith("PR の URL を確認できませんでした。"))) | length == 1' "$test_dir/posted.jsonl"
	fi
done
echo 'PASS no-integration: 紐付けの知らせも、ci_watch_thread への名簿のエージェントの返信だけを知らせ済みと読む'

# 名簿を読めない（読み取りの失敗、終了コード 1）ときは、3 つの知らせのどれも書かず、規則を残して 1 で終わる。
link_stop_scene
echo 'squad member list' >"$test_dir/fail"
unlinked_run
((unlinked_status == 1))
rule_kept
no_posts
grep -q '名簿を読めないため' "$test_dir/err"
unlinked_scene record
same_pr_round
update_pr '.state = "MERGED"'
echo 'squad member list' >"$test_dir/fail"
unlinked_run
((unlinked_status == 1))
rule_kept
no_posts
rm -f "$test_dir/fail"
# 見張りの終わりの知らせは、名簿を読めないと照合のところで待つので、前の「名簿を読めるまで見張りの終わりの知らせを待つ」の場面で見ている。
# 担当がスクワッドから変わった（終了コード 2）ときは、名簿を読めているので、知らせ済みの返信が無いものとして紐付けの知らせを 1 回書いて規則を消す。見張りの終わりの知らせは、照合が「合わない」で書かないので、繰り返さない。
link_stop_scene
change_assignee
unlinked_run
((unlinked_status == 0)) || { echo "FAIL 担当が変わった紐付けの知らせ: 終了コード $unlinked_status" >&2; cat "$test_dir/err" >&2; exit 1; }
rule_gone
assert_jq -s 'map(select(.body | startswith("PR の URL を確認できませんでした。"))) | length == 1' "$test_dir/posted.jsonl"
unlinked_scene record "$(stamp -$((71 * 3600 + 60)))"
change_assignee
unlinked_run
((unlinked_status == 0)) || { echo "FAIL 担当が変わった終わりの知らせ: 終了コード $unlinked_status" >&2; cat "$test_dir/err" >&2; exit 1; }
no_notice
rule_kept
unlinked_run
no_notice
echo 'PASS no-integration: 名簿を読めないときは、知らせを書かず、規則を残して 1 で終わる'

# done の照合の 5 と head。次の入力は、どれもマージされても done にせず、理由と知らせを出して止める。
# 依頼が規則の回を指し、作者と head がそろうときだけ done にする（前の場面の merge-1 と、下の大文字小文字の場面）。
hand_request() { drop_request; add_comment merge-x agent orchestrator "マージの依頼: $merge_head"; }
prepare_extra=hand_request merged_refuses '名簿のリーダーが前の回なしで手でマージを頼んだ'
other_pr_round_request() {
	drop_request
	prepend_comment other-round agent orchestrator "$(round_body "$other")"
	add_comment merge-x agent orchestrator "$(merge_request_body "$merge_head" other-round)"
}
prepare_extra=other_pr_round_request merged_refuses '同じ head の依頼が、別の PR の回を前の回に指す'
old_round_request() {
	drop_request
	prepend_comment round-0 agent orchestrator "$(round_body "$pr")"
	add_comment merge-x agent orchestrator "$(merge_request_body "$merge_head" round-0)"
}
prepare_extra=old_round_request merged_refuses '規則の回より後に、前の回を指す依頼'
role_request() { drop_request; add_comment merge-x agent monitor "$(merge_request_body)"; }
prepare_extra=role_request merged_refuses '規則の回を指す依頼を、その回を決める実行でない役が書いた'
two_prev_request() { drop_request; add_comment merge-x agent orchestrator "$(merge_request_body)"$'\n前の回: other-round'; }
prepare_extra=two_prev_request merged_refuses '前の回の行が 2 つ'
short_request() { drop_request; add_comment merge-x agent orchestrator "$(merge_request_body abcdef0)"; }
prepare_extra=short_request merged_refuses '依頼の head が 40 桁でない'
pushed_head() { update_pr '.headRefOid = "abcdef0000000000000000000000000000000002"'; }
prepare_extra=pushed_head merged_refuses '依頼のあとの push で、マージした head が依頼の head と違う（回のコミットで始まる）'
grep -q 'マージの依頼がない' "$test_dir/err"
pushed_other() { update_pr '.headRefOid = "1111111111111111111111111111111111111111"'; }
prepare_extra=pushed_other merged_refuses 'マージした head が回の確認するコミットと違う'
grep -q 'マージした head（1111111111111111111111111111111111111111）が回の確認するコミット（abcdef0）と違う' "$test_dir/err"
unset prepare_extra
echo 'PASS no-integration: 依頼の作者・回・head のどれかが合わなければ、done にせず、理由と知らせを出して止める'

# 依頼の head と headRefOid は、大文字小文字を問わず同じなら done にする。
for case in request pr; do
	unlinked_scene record
	upper=$(tr '[:lower:]' '[:upper:]' <<<"$merge_head")
	if [[ $case == request ]]; then
		drop_request
		add_comment merge-x agent orchestrator "$(merge_request_body "$upper")"
	else
		update_pr ".headRefOid = \"$upper\""
	fi
	update_pr '.state = "MERGED"'
	unlinked_run
	((unlinked_status == 0)) || { echo "FAIL 大文字（$case）: 終了コード $unlinked_status" >&2; cat "$test_dir/err" >&2; exit 1; }
	assert_jq '.status == "done"' "$test_dir/task.json"
	rule_gone
	no_posts
done
echo 'PASS no-integration: 依頼の head と headRefOid は、大文字小文字を問わず同じなら done にする'

# gh の応答に headRefOid がないときは、PR の状態を読めないので、done にもマージ後の知らせにもせず、規則を残して 1 で終わる。
unlinked_scene record
update_pr '.state = "MERGED" | del(.headRefOid)'
unlinked_run
((unlinked_status == 1))
[[ $(done_calls) == '[]' ]]
assert_jq '.status == "in_review"' "$test_dir/task.json"
rule_kept
assert_jq -s "$not_done_filter | length == 0" "$test_dir/posted.jsonl"
no_notice
echo 'PASS no-integration: headRefOid を読めないときは、規則を残して 1 で終わる'
