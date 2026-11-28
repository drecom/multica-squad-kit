#!/usr/bin/env bash
# 字下げの根拠がある診断の依頼など、手で書いた読めない依頼に役が返したとき、report が結果を回に付けずに保存し、
# 候補ごとの知らせを書いてリーダーを起こすことを確認する。場面は docs/review-next-step.md の「読めない候補の知らせ」と「入力と信頼の表」。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/review-wait-test-lib.sh"

export MULTICA_AGENT_ID=$b
squad_mention='[@demo-squad](mention://squad/squad-test) 返事がそろいました。'

diagnosis_body="見直しの種類: 診断
診断の依頼: 2 回目。失敗: 同じ誤り 検証
返事を待つ役: [@qa](mention://agent/$b)

続いた失敗の根拠:
  - 同じ検証が失敗した"
div_body="返事を待つ役: [@qa](mention://agent/$b)
<div>"

# 1 件の知らせの本文。作者・時刻・スクワッドを変えて、入力の信頼の表の条件を 1 つずつ外すのに使う。
notice_body() { # 候補の ID 行 理由 [スクワッドの ID] [名前]
	printf '[@%s](mention://squad/%s) 返事がそろいました。\n次の依頼を決められません: 制御記録を読めない（%s: %s 行目: %s）\n読めない制御記録: %s %s 行目: %s\n保存した結果: earlier\n' \
		"${5:-demo-squad}" "${4:-squad-test}" "$1" "$2" "$3" "$1" "$2" "$3"
}

# 結果の保存・名乗り・知らせの 3 件が、期待どおりに並んだことを確認する。
expect_notice_posts() { # 結果に付く回の値 候補の ID 行 理由
	assert_jq -s --arg value "$1" --arg id "$2" --arg line "$3" --arg reason "$4" --arg mention "$squad_mention" '
		length == 3
		and .[0].body == "/note\nqa result\n返事の回: " + $value + "\n"
		and .[1].body == "/note\n読めない制御記録の知らせ: " + $id + " squad-test\n"
		and (.[2].body | startswith($mention + "\n次の依頼を決められません: 制御記録を読めない（" + $id + ": " + $line + " 行目: " + $reason + "）\n"))
		and (.[2].body | contains("\n読めない制御記録: " + $id + " " + $line + " 行目: " + $reason + "\n"))
		and (.[2].body | contains("\n保存した結果: posted-1\n"))
		and (.[2].body | contains("mention://agent/") | not)
		and all(.[]; .args | index("--parent") as $i | .[$i+1] == "diagnosis")' "$test_dir/posted.jsonl"
}

# report を流す。終了コードを code に入れる。標準エラーは error に入れる。
run_report() {
	code=0
	bash "$script" report test-issue diagnosis "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error" || code=$?
}
expect_exit() { # 期待する終了コード
	[[ $code == "$1" ]] || { printf '終了コード %s を期待したが %s: %s\n' "$1" "$code" "$(<"$test_dir/error")" >&2; exit 1; }
}
# スクワッドが決まらないとき、何も書かず、待たず、決める記録も書かない。
expect_nothing_written() {
	[[ ! -s $test_dir/posted.jsonl && -z $(slept) ]] || {
		printf 'スクワッドが決まらないときは、何も書いてはいけない: %s / %s / %s\n' "$(<"$test_dir/posted.jsonl")" "$(<"$test_dir/error")" "$(slept)" >&2
		exit 1
	}
}
expect_no_decide() {
	[[ $(posted_decide_count) == 0 && -z $(decide_calls) ]] || { echo '決める記録を書いても decide を流してもいけない' >&2; exit 1; }
}

# 診断の依頼を置いた一覧を作る。引数は build_comments と同じ。名乗りは見えるようにする。
report_diagnosis() {
	reset_calls
	build_comments "$@" | with_raw diagnosis orchestrator agent 10 "$diagnosis_body" >"$test_dir/comments.json"
	claim_visible_at_3 diagnosis
	run_report
}

# 5-1、7-1: 回の記録がなくても、同じ実行で結果を回に付けずに保存し、知らせを書いて終了 0 になる。待ちは 1 回、見張りの起こしは挟まない。
report_diagnosis
expect_exit 0
expect_notice_posts '未定（読めない依頼 diagnosis）' diagnosis 6 '行頭の空白'
expect_no_decide
[[ $(slept) == 20 && $(list_count) == 3 ]] || { printf '待ちは 20 秒を 1 回、読み直しは 3 回: %s %s\n' "$(slept)" "$(list_count)" >&2; exit 1; }
echo 'PASS report: 読めない依頼へ返すと、結果は回に付けずに保存し、名乗りと知らせを書いて終了 0 になる'

# 6-1: 次の依頼・決める記録・知らせのある前の回があっても、同じく書く。
report_diagnosis result:a:review-result:3 result:b:qa-result:4 \
	decide:a:previous-decision:5 next:a:previous-next:6 ready:a:previous-notice:7
expect_exit 0
expect_notice_posts '未定（読めない依頼 diagnosis）' diagnosis 6 '行頭の空白'
expect_no_decide
echo 'PASS report: 前の回に次の依頼・決める記録・知らせがあっても、結果を保存して知らせを書く'

# 5-2: 名乗りが 1 回目の読み直しで見えなければ、もう 1 回待つ。合わせて 40 秒以内。見えなければ知らせずに終了 1 になる。
reset_calls
build_comments | with_raw diagnosis orchestrator agent 10 "$diagnosis_body" >"$test_dir/comments.json"
cp "$test_dir/comments.json" "$test_dir/comments.3.json"
with_claim posted-2 "$b" 12 diagnosis squad-test <"$test_dir/comments.json" >"$test_dir/comments.4.json"
run_report
expect_exit 0
[[ $(slept) == 20,20 && $(list_count) == 4 ]] || { printf '待ちは 20 秒を 2 回: %s %s\n' "$(slept)" "$(list_count)" >&2; exit 1; }
assert_jq -s 'length == 3' "$test_dir/posted.jsonl"
reset_calls
build_comments | with_raw diagnosis orchestrator agent 10 "$diagnosis_body" >"$test_dir/comments.json"
run_report
expect_exit 1
[[ $(slept) == 20,20 ]] || { printf '待ちは 20 秒を 2 回で打ち切る: %s\n' "$(slept)" >&2; exit 1; }
assert_jq -s 'length == 2 and (.[1].body | startswith("/note\n読めない制御記録の知らせ:"))' "$test_dir/posted.jsonl"
[[ $(<"$test_dir/error") == *'名乗りが読み直しで見えません'* && $(<"$test_dir/error") == *'squad-handoff'* ]]
echo 'PASS report: 名乗りが 40 秒以内に見えなければ、知らせを書かずに終了 1 になる'

# 5-3: 知らせるスクワッドは、タスクの担当がスクワッドならそのスクワッド。
other_squad() { # アーカイブ済みにするなら archived
	jq --arg state "${1:-}" '. + [.[0] + {id: "squad-other", name: "other-squad", leader_id: "other-leader", archived_at: (if $state == "archived" then "2026-01-01T00:00:00Z" else null end)}]' \
		"$test_dir/squads.base.json" >"$test_dir/squads.json"
}
prepare_other() { # 担当の種類 担当の ID 候補の本文 [アーカイブ]
	reset_calls
	other_squad "${4:-}"
	set_assignee "$1" "$2"
	build_comments | with_raw diagnosis orchestrator agent 10 "$3" >"$test_dir/comments.json"
}
prepare_other squad squad-other "$diagnosis_body"
with_claim posted-2 "$b" 12 diagnosis squad-other <"$test_dir/comments.json" >"$test_dir/comments.3.json"
run_report
expect_exit 0
assert_jq -s '.[1].body == "/note\n読めない制御記録の知らせ: diagnosis squad-other\n"
	and (.[2].body | startswith("[@other-squad](mention://squad/squad-other) 返事がそろいました。\n"))' "$test_dir/posted.jsonl"
# 担当がスクワッドでないときは、認める回の作者をリーダーとするスクワッドに知らせる。
for assignee in 'agent agent-a' 'member member-x'; do
	# shellcheck disable=SC2086
	prepare_other $assignee "$diagnosis_body"
	claim_visible_at_3 diagnosis
	run_report
	expect_exit 0
	expect_notice_posts '未定（読めない依頼 diagnosis）' diagnosis 6 '行頭の空白'
done
# 担当のスクワッドがアーカイブ済みでも、回から決める。
prepare_other squad squad-other "$diagnosis_body" archived
claim_visible_at_3 diagnosis
run_report
expect_exit 0
expect_notice_posts '未定（読めない依頼 diagnosis）' diagnosis 6 '行頭の空白'
# 回が決める実行の役が書いた回（前の回: でつながる）のときは、囲みの外の前の回: をたどってリーダーの回のスクワッドに知らせる。
reset_calls
set_assignee agent agent-a
build_comments decide:b:decide-record:2 |
	with_raw round2 "$b" agent 3 "返事を待つ役: [@qa](mention://agent/$b)
コミットが合わず頼み直す役: [@qa](mention://agent/$b)
前の回: round" |
	with_raw diagnosis orchestrator agent 10 "$diagnosis_body" >"$test_dir/comments.json"
claim_visible_at_3 diagnosis
run_report
expect_exit 0
expect_notice_posts '未定（読めない依頼 diagnosis）' diagnosis 6 '行頭の空白'
# 担当がなく、回の作者がどのスクワッドのリーダーでもないときも、何も書かず終了 1 になる。
prepare_other agent agent-a "$diagnosis_body"
jq 'map(if .id == "round" then . + {author_id: "stranger"} else . end)' "$test_dir/comments.json" >"$test_dir/comments.tmp.json"
cp "$test_dir/comments.tmp.json" "$test_dir/comments.json"
run_report
expect_exit 1
expect_nothing_written
# 担当がなく、認める回もないときも、何も書かず終了 1 になる。回がなければ担当のスクワッドから決められる。
prepare_other agent agent-a "$diagnosis_body"
printf '[]\n' | with_raw diagnosis orchestrator agent 10 "$diagnosis_body" >"$test_dir/comments.json"
run_report
expect_exit 1
expect_nothing_written
reset_calls
printf '[]\n' | with_raw diagnosis orchestrator agent 10 "$diagnosis_body" >"$test_dir/comments.json"
claim_visible_at_3 diagnosis
run_report
expect_exit 0
expect_notice_posts '未定（読めない依頼 diagnosis）' diagnosis 6 '行頭の空白'
# リーダーでない役が書いた候補だけで認める回がなくても、担当のスクワッドへ知らせる（候補の作者からは決めない）。
reset_calls
printf '[]\n' | with_raw diagnosis agent-a agent 10 "$diagnosis_body" >"$test_dir/comments.json"
claim_visible_at_3 diagnosis
run_report
expect_exit 0
expect_notice_posts '未定（読めない依頼 diagnosis）' diagnosis 6 '行頭の空白'
echo 'PASS report: 知らせるスクワッドは、担当がスクワッドならそのスクワッド、そうでなければ回から決め、決まらなければ何も書かず終了 1 になる'

# 7-2: 読めない候補が 2 つあると、候補ごとに別の知らせを書く。結果は最後の依頼の候補を指す。
reset_calls
build_comments | with_raw diagnosis orchestrator agent 10 "$diagnosis_body" | with_raw second orchestrator agent 11 "$div_body" >"$test_dir/comments.json"
{
	with_claim posted-2 "$b" 12 diagnosis squad-test <"$test_dir/comments.json" |
		with_claim posted-3 "$b" 13 second squad-test
} >"$test_dir/comments.3.json"
run_report
expect_exit 0
assert_jq -s --arg mention "$squad_mention" 'length == 5
	and .[0].body == "/note\nqa result\n返事の回: 未定（読めない依頼 second）\n"
	and .[1].body == "/note\n読めない制御記録の知らせ: diagnosis squad-test\n"
	and .[2].body == "/note\n読めない制御記録の知らせ: second squad-test\n"
	and (.[3].body | startswith($mention) and contains("\n読めない制御記録: diagnosis 6 行目: 行頭の空白\n") and (contains("second") | not) and contains("保存した結果: posted-1\n"))
	and (.[4].body | startswith($mention) and contains("\n読めない制御記録: second 2 行目: HTML\n") and (contains("diagnosis") | not))' "$test_dir/posted.jsonl"
expect_no_decide
# あとから足された候補には、その候補の知らせだけを書く。知らせ済みの候補には書かない。
reset_calls
build_comments | with_raw diagnosis orchestrator agent 10 "$diagnosis_body" | with_raw earlier-notice agent-a agent 11 "$(notice_body diagnosis 6 行頭の空白)" |
	with_raw second orchestrator agent 12 "$div_body" >"$test_dir/comments.json"
with_claim posted-2 "$b" 13 second squad-test <"$test_dir/comments.json" >"$test_dir/comments.3.json"
run_report
expect_exit 0
assert_jq -s 'length == 3 and .[1].body == "/note\n読めない制御記録の知らせ: second squad-test\n"
	and (.[2].body | contains("読めない制御記録: second 2 行目: HTML") and (contains("diagnosis") | not))' "$test_dir/posted.jsonl"
echo 'PASS report: 読めない候補が 2 つなら知らせも 2 つ。知らせ済みの候補には書かない'

# 8-1: 2 つの役が順に返しても、知らせは 1 つだけ。2 つ目の役は、結果を保存するだけで、名乗りも知らせも書かない。
reset_calls
build_comments | with_raw diagnosis orchestrator agent 10 "$diagnosis_body" |
	with_raw first-result agent-a agent 11 $'/note\nreview result\n返事の回: 未定（読めない依頼 diagnosis）\n' |
	with_raw first-claim agent-a agent 12 "$(printf '/note\n読めない制御記録の知らせ: diagnosis squad-test\n')" |
	with_raw first-notice agent-a agent 13 "$(notice_body diagnosis 6 行頭の空白)" >"$test_dir/comments.json"
run_report
expect_exit 0
assert_jq -s 'length == 1 and .[0].body == "/note\nqa result\n返事の回: 未定（読めない依頼 diagnosis）\n"' "$test_dir/posted.jsonl"
[[ -z $(slept) ]] || { echo '知らせ済みなら待たない' >&2; exit 1; }
expect_no_decide
echo 'PASS report: 同じ読めないコメントに 2 つの役が順に返しても、知らせは 1 つだけ'

# 8-3: 回を付けずに保存した結果は、候補にも回にもならない。知らせがまだなら、候補は元のコメント 1 つで、知らせも 1 つ。
reset_calls
build_comments | with_raw diagnosis orchestrator agent 10 "$diagnosis_body" |
	with_raw first-result agent-a agent 11 $'/note\nreview result\n返事の回: 未定（読めない依頼 diagnosis）\n' >"$test_dir/comments.json"
claim_visible_at_3 diagnosis
run_report
expect_exit 0
assert_jq -s 'length == 3
	and ([.[].body | select(startswith("[@demo-squad]"))] | length) == 1
	and .[0].body == "/note\nqa result\n返事の回: 未定（読めない依頼 diagnosis）\n"
	and ([.[2].body | scan("読めない制御記録: ")] | length) == 1' "$test_dir/posted.jsonl"
# 保存した結果の `返事の回:` の値は、どのコメントの ID でもないので、どの回の返事の組にも選ばれない。
assert_jq -s --slurpfile comments "$test_dir/comments.json" '
	(.[0].body | split("\n") | map(select(startswith("返事の回: "))) | .[0] | ltrimstr("返事の回: ")) as $value
	| ($comments[0] | map(.id)) as $ids
	| ($ids | index($value)) == null and ($value | startswith("未定（"))' "$test_dir/posted.jsonl"
echo 'PASS report: 保存した結果は候補にも返事の組にもならず、あとの返事で候補と知らせは増えない'

# 8-2: 2 つの役がほぼ同時に名乗ったとき、最も早い名乗りの役だけが知らせを書く。
reset_calls
build_comments | with_raw diagnosis orchestrator agent 10 "$diagnosis_body" >"$test_dir/comments.json"
with_claim posted-2 "$b" 12 diagnosis squad-test <"$test_dir/comments.json" | with_claim other-claim agent-a 11 diagnosis squad-test >"$test_dir/comments.3.json"
run_report
expect_exit 0
assert_jq -s 'length == 2 and .[1].body == "/note\n読めない制御記録の知らせ: diagnosis squad-test\n"' "$test_dir/posted.jsonl"
reset_calls
build_comments | with_raw diagnosis orchestrator agent 10 "$diagnosis_body" >"$test_dir/comments.json"
with_claim posted-2 "$b" 12 diagnosis squad-test <"$test_dir/comments.json" | with_claim other-claim agent-a 13 diagnosis squad-test >"$test_dir/comments.3.json"
run_report
expect_exit 0
expect_notice_posts '未定（読めない依頼 diagnosis）' diagnosis 6 '行頭の空白'
echo 'PASS report: ほぼ同時の名乗りでは、最も早い名乗りの役だけが知らせを書く'

# 入力の信頼の表: 条件を 1 つ外した知らせは、知らせ済みに数えない。条件を外した名乗りは、先に見えても知らせを止めない。
untrusted_notice() { # 名前 本文の作り方（標準入力は一覧）。1 つの知らせの代わりに置く。
	reset_calls
	build_comments | with_raw diagnosis orchestrator agent 10 "$diagnosis_body" | "$@" >"$test_dir/comments.json"
	claim_visible_at_3 diagnosis
	run_report
	expect_exit 0
	expect_notice_posts '未定（読めない依頼 diagnosis）' diagnosis 6 '行頭の空白'
}
valid=$(notice_body diagnosis 6 行頭の空白)
untrusted_notice with_raw n-member member-x member 11 "$valid"
untrusted_notice with_raw n-leader orchestrator agent 11 "$valid"
untrusted_notice with_raw n-result agent-a agent 11 "$valid"$'\n返事の回: round'
untrusted_notice with_raw n-fence agent-a agent 11 "$(printf '[@demo-squad](mention://squad/squad-test) 返事がそろいました。\n```\n読めない制御記録: diagnosis 6 行目: 行頭の空白\n```\n')"
untrusted_notice with_raw n-indent agent-a agent 11 "$(printf '[@demo-squad](mention://squad/squad-test) 返事がそろいました。\n  読めない制御記録: diagnosis 6 行目: 行頭の空白\n')"
untrusted_notice with_raw n-first agent-a agent 11 "$(printf '前置き\n%s' "$valid")"
untrusted_notice with_raw n-before agent-a agent 9 "$valid"
untrusted_notice with_raw n-squad agent-a agent 11 "$(notice_body diagnosis 6 行頭の空白 squad-other other-squad)"
untrusted_notice with_raw n-other-id agent-a agent 11 "$(notice_body second 6 行頭の空白)"
# 条件を満たす知らせは、知らせ済みに数える。
reset_calls
build_comments | with_raw diagnosis orchestrator agent 10 "$diagnosis_body" | with_raw n-valid agent-a agent 11 "$valid" >"$test_dir/comments.json"
run_report
expect_exit 0
assert_jq -s 'length == 1' "$test_dir/posted.jsonl"
# 条件を外した名乗りが先に見えても、自分の知らせを書く。
untrusted_claim() { # 作者の ID 作者の種類 時刻 本文
	reset_calls
	build_comments | with_raw diagnosis orchestrator agent 10 "$diagnosis_body" >"$test_dir/comments.json"
	with_claim posted-2 "$b" 12 diagnosis squad-test <"$test_dir/comments.json" | with_raw early-claim "$1" "$2" "$3" "$4" >"$test_dir/comments.3.json"
	run_report
	expect_exit 0
	expect_notice_posts '未定（読めない依頼 diagnosis）' diagnosis 6 '行頭の空白'
}
claim=$'/note\n読めない制御記録の知らせ: diagnosis squad-test\n'
untrusted_claim member-x member 11 "$claim"
untrusted_claim orchestrator agent 11 "$claim"
untrusted_claim agent-a agent 11 "${claim}返事の回: round"
untrusted_claim agent-a agent 11 $'/note\n  読めない制御記録の知らせ: diagnosis squad-test\n'
untrusted_claim agent-a agent 11 $'/note\n```\n読めない制御記録の知らせ: diagnosis squad-test\n```\n'
untrusted_claim agent-a agent 11 $'前置き\n読めない制御記録の知らせ: diagnosis squad-test\n'
untrusted_claim agent-a agent 9 "$claim"
untrusted_claim agent-a agent 11 $'/note\n読めない制御記録の知らせ: diagnosis squad-other\n'
echo 'PASS report: 条件を外した知らせと名乗りは、知らせ済み・先の名乗りに数えない'
