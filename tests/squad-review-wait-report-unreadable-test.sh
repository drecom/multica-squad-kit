#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-wait-report-unreadable-test.sh で実行する。
# squad-review-wait report が、最新の回の候補が読めないとき、決める記録を書かず、decide も流さず、結果の保存・名乗り・知らせでリーダーを起こすことを確認する。
# 候補が round（回の候補）なら結果を回に付けずに保存し、record（次の依頼・決める記録・名乗りの候補）だけなら今のとおり最新の回に書く。
# 場面は docs/review-next-step.md の「本文の読み方のテスト」の表 2 の report の行。理由の出し方は「候補と読めないときの扱い」の表。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/review-wait-test-lib.sh"

round_ts=$((now - 120))
both='result:a:r1:5 result:b:r2:6'
own_record='decide:a:posted-2:90'

# 候補は、回より後に作者がエージェントで書かれ、返事を待つ役: を含むコメント。読めない書き方で置く（round の候補）。
# 3 つ目の引数は、回の返事の組（既定は両方が返した組）。返していない役がいても、読めない候補が優先される。
# 結果は回に付けずに保存し、名乗りと知らせを書く。終了は 0。
reason_body() { # 本文の JSON 文字列 「<行> 行目: <理由>」 [返事の組]
	local json=$1 line=$2 replies=${3:-$both}
	reset_calls
	# shellcheck disable=SC2086
	build_comments $replies | with_json x orchestrator agent 8 "$json" >"$test_dir/comments.json"
	claim_visible_at_3 x
	run_report
	assert_jq -s --arg line "$line" 'length == 3
		and .[0].body == "/note\nqa result\n返事の回: 未定（読めない依頼 x）\n"
		and .[1].body == "/note\n読めない制御記録の知らせ: x squad-test\n"
		and (.[2].body | startswith("[@demo-squad](mention://squad/squad-test) 返事がそろいました。\n次の依頼を決められません: 制御記録を読めない（x: " + $line + "）\n"))
		and (.[2].body | contains("\n読めない制御記録: x " + $line + "\n"))
		and (.[2].body | contains("\n保存した結果: posted-1\n"))
		and (.[2].body | contains("mention://agent/") | not)
		and all(.[]; .args | index("--parent") as $i | .[$i+1] == "trigger")' "$test_dir/posted.jsonl"
}

run_report() {
	code=0
	bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error" || code=$?
	[[ $code == 0 ]] || { printf '終了コード 0 を期待したが %s: %s\n' "$code" "$(<"$test_dir/error")" >&2; exit 1; }
	[[ $(posted_decide_count) == 0 ]] || { echo '決める記録を書いてはいけない' >&2; exit 1; }
	[[ -z $(decide_calls) ]] || { echo 'decide を流してはいけない' >&2; exit 1; }
	expect_slept_within 50
}

reason_body "$(jq -nc '"> 返事を待つ役: [@qa](mention://agent/a)\n確認するコミット: abc"')" '1 行目: 引用'
reason_body "$(jq -nc '"返事を待つ役: [@qa](mention://agent/a)\n  字下げ"')" '2 行目: 行頭の空白'
reason_body "$(jq -nc '"返事を待つ役: [@qa](mention://agent/a)\n<div>"')" '2 行目: HTML'
reason_body "$(jq -nc '"返事を待つ役: [@qa](mention://agent/a)\n```\n囲みが閉じない"')" '2 行目: 閉じない囲み'
echo 'PASS report: 最新の回の候補が読めなければ、結果は書き、決める記録も decide も書かず、理由つきの決まらない知らせでスクワッドのリーダーを起こす'
# 同じ回の返事がそろっていなくても（返していない役がいても）、読めない候補があれば、結果と知らせの 2 件を書く。
# 返していない役の返事を待たない。読めない候補は、役の返事では解けない。
for replies in 'result:a:r1:5' 'result:b:r2:6'; do
	reason_body "$(jq -nc '"> 返事を待つ役: [@qa](mention://agent/a)\n確認するコミット: abc"')" '1 行目: 引用' "$replies"
	reason_body "$(jq -nc '"返事を待つ役: [@qa](mention://agent/a)\n  字下げ"')" '2 行目: 行頭の空白' "$replies"
	reason_body "$(jq -nc '"返事を待つ役: [@qa](mention://agent/a)\n<div>"')" '2 行目: HTML' "$replies"
	reason_body "$(jq -nc '"返事を待つ役: [@qa](mention://agent/a)\n```\n囲みが閉じない"')" '2 行目: 閉じない囲み' "$replies"
done
echo 'PASS report: 返していない役がいる回でも、読めない候補を優先し、結果と理由つきの知らせを 1 回ずつ書く'

# 6-2: 最新の回の record の候補（前の回: round を含む次の依頼）だけが読めないとき、結果は今のとおり最新の回に書き、名乗りと知らせを書く。
# 回に付けるので、知らせは待っていた役を並べる形になる。
record_only() { # 返事の組
	reset_calls
	# shellcheck disable=SC2086
	build_comments $1 | with_json x orchestrator agent 8 "$(jq -nc '"修正の依頼: 直してください\n前の回: round\n  字下げ"')" >"$test_dir/comments.json"
	claim_visible_at_3 x
	run_report
	assert_jq -s 'length == 3
		and .[0].body == "/note\nqa result\n返事の回: round\n"
		and .[1].body == "/note\n読めない制御記録の知らせ: x squad-test\n"
		and (.[2].body | startswith("[@demo-squad](mention://squad/squad-test) 返事がそろいました。\n次の依頼を決められません: 制御記録を読めない（x: 3 行目: 行頭の空白）\n"))
		and (.[2].body | contains("\n読めない制御記録: x 3 行目: 行頭の空白\n") and contains("\n保存した結果: posted-1\n"))
		and (.[2].body | contains("- demo-code-reviewer-test\n") and contains("- demo-qa-test\n"))' "$test_dir/posted.jsonl"
}
record_only "$both"
record_only 'result:a:r1:5'
echo 'PASS report: record の候補だけが読めないときは、結果を最新の回に書き、知らせの形で終了 0 になる'

# 6-1: 最新の回に次の依頼・次へ回す記録・決める記録・知らせがあっても、新しい読めない候補は知らせる。知らせがなければ失敗する。
# 新しい依頼が読めないと、最新の認める回は前の回のままで、その回にはもう記録がある。
for existing in decide:b:d1:7 next:orch:n1:7 claim:orch:c1:7 ready:orch:k1:7; do
	reason_body "$(jq -nc '"> 返事を待つ役: [@qa](mention://agent/a)\n確認するコミット: abc"')" '1 行目: 引用' "$both $existing"
	reason_body "$(jq -nc '"返事を待つ役: [@qa](mention://agent/a)\n  字下げ"')" '2 行目: 行頭の空白' "result:a:r1:5 $existing"
	# record の候補。結果は最新の回に書き、知らせは待っていた役を並べる形になる。
	reset_calls
	# shellcheck disable=SC2086
	build_comments $both $existing | with_json x orchestrator agent 8 "$(jq -nc '"修正の依頼: 直してください\n前の回: round\n  字下げ"')" >"$test_dir/comments.json"
	claim_visible_at_3 x
	run_report
	assert_jq -s 'length == 3
		and .[0].body == "/note\nqa result\n返事の回: round\n"
		and (.[2].body | startswith("[@demo-squad](mention://squad/squad-test) 返事がそろいました。\n次の依頼を決められません: 制御記録を読めない（x: 3 行目: 行頭の空白）\n"))' "$test_dir/posted.jsonl"
done
echo 'PASS report: 最新の回に記録や知らせがあっても、新しい読めない候補には結果の保存と知らせを書く'

# 5-1: どの道でも、偽の sleep の合計は 50 秒以下。期限（60 秒）から取り置き（10 秒）を引いた時刻までしか待たない。
# 上のどの場面の run_report でも、合計を確認している。ここでは、返事の待ちを 2 回使ったあとに読めない候補が見える道を使う。
# 取得の順: 1 回目が結果の投稿前、2 回目が結果の投稿後、3 回目が決める記録の投稿後、4 回目が 2 回目の settle。
# 決める記録が 3 回目と 4 回目の読み直しで見えず、5 回目で読めない候補が現れる。20 秒待つのが 2 回で、40 秒になる。
# 返事の待ちが 20,20 のあと、名乗りの待ちは残りの秒数（最大 10）で切る。実際の経過秒も SECONDS に入るので、3 つ目の秒数は実行の速さで変わる。
# 残りがなければ 3 つ目は待たない。どちらでも、合計は 40 秒以上 50 秒以下で、1 回の待ちは 20 秒を超えない。
expect_waits_cut_at_deadline() {
	local total
	total=$(slept_total)
	[[ $(slept) == 20,20 || $(slept) == 20,20,[0-9] || $(slept) == 20,20,10 ]] && ((total >= 40 && total <= 50)) || {
		printf '待ちは 20,20 のあと、残りの 10 秒以内だけ: %s\n' "$(slept)" >&2
		exit 1
	}
}
unreadable_after_waits() { # 名乗りが見える取得の番号（なければ空）
	reset_calls
	local n
	for n in 1 2 3 4; do build_comments $both >"$test_dir/comments.$n.json"; done
	for n in 5 6 7; do
		build_comments $both | with_json x orchestrator agent 8 "$(jq -nc '"修正の依頼: 直してください\n前の回: round\n  字下げ"')" >"$test_dir/comments.$n.json"
	done
	cp "$test_dir/comments.7.json" "$test_dir/comments.json"
	if [[ -n $1 ]]; then
		with_claim posted-3 "$b" 12 x squad-test <"$test_dir/comments.7.json" >"$test_dir/comments.$1.json"
		cp "$test_dir/comments.$1.json" "$test_dir/comments.json"
	fi
	code=0
	bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error" || code=$?
	[[ -z $(decide_calls) ]] || { echo 'decide を流してはいけない' >&2; exit 1; }
	expect_slept_within 50
}
unreadable_after_waits 8
[[ $code == 0 ]] || { printf '終了コード 0 を期待したが %s: %s\n' "$code" "$(<"$test_dir/error")" >&2; exit 1; }
expect_waits_cut_at_deadline
assert_jq -s 'length == 4
	and .[0].body == "/note\nqa result\n返事の回: round\n"
	and .[1].body == "/note\n返事の待ち: 次の依頼を決めます\n"
	and .[2].body == "/note\n読めない制御記録の知らせ: x squad-test\n"
	and (.[3].body | startswith("[@demo-squad](mention://squad/squad-test) 返事がそろいました。\n次の依頼を決められません: 制御記録を読めない（x: 3 行目: 行頭の空白）\n"))' "$test_dir/posted.jsonl"
# 名乗りが 1 回目の読み直しで見えなければ、残りがないので、もう待たない。知らせは書かず、終了 1 になる。
unreadable_after_waits ''
[[ $code == 1 ]] || { printf '終了コード 1 を期待したが %s: %s\n' "$code" "$(<"$test_dir/error")" >&2; exit 1; }
expect_waits_cut_at_deadline
[[ $(<"$test_dir/error") == *'名乗りが読み直しで見えません'* && $(<"$test_dir/error") == *'squad-handoff'* ]] || { printf '名乗りが見えないときの案内: %s\n' "$(<"$test_dir/error")" >&2; exit 1; }
assert_jq -s 'length == 3 and (.[2].body | startswith("/note\n読めない制御記録の知らせ:"))' "$test_dir/posted.jsonl"
echo 'PASS report: 返事の待ちのあとに読めない候補が見えても、待ちは開始から 50 秒までで、知らせを書くか終了 1 になる'

# 5-2: 決める記録を書いたあとの読み直しで読めない候補が現れたら、decide を流さず、決める記録は消さず、知らせを書く。
# 取得の順: 1 回目が結果の投稿前、2 回目が結果の投稿後、3 回目が決める記録の投稿後（ここで読めない候補が現れる）。
reset_calls
build_comments $both >"$test_dir/comments.1.json"
cp "$test_dir/comments.1.json" "$test_dir/comments.2.json"
for n in 3 4 5; do
	build_comments $both "$own_record" | with_json x orchestrator agent 95 "$(jq -nc '"修正の依頼: 直してください\n前の回: round\n  字下げ"')" >"$test_dir/comments.$n.json"
done
with_claim posted-3 "$b" 96 x squad-test <"$test_dir/comments.5.json" >"$test_dir/comments.json"
code=0
bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error" || code=$?
[[ $code == 0 ]] || { printf '終了コード 0 を期待したが %s: %s\n' "$code" "$(<"$test_dir/error")" >&2; exit 1; }
[[ -z $(decide_calls) && $(posted_decide_count) == 1 ]] || { echo 'decide を流さず、決める記録は 1 つのまま残す' >&2; exit 1; }
[[ $(slept) == 20 ]] || { printf '名乗りの確認の待ちは 20 秒を 1 回: %s\n' "$(slept)" >&2; exit 1; }
expect_slept_within 50
assert_jq -s 'length == 4
	and .[0].body == "/note\nqa result\n返事の回: round\n"
	and .[1].body == "/note\n返事の待ち: 次の依頼を決めます\n"
	and .[2].body == "/note\n読めない制御記録の知らせ: x squad-test\n"
	and (.[3].body | startswith("[@demo-squad](mention://squad/squad-test) 返事がそろいました。\n次の依頼を決められません: 制御記録を読めない（x: 3 行目: 行頭の空白）\n"))
	and (.[3].body | contains("\n保存した結果: posted-1\n"))' "$test_dir/posted.jsonl"
echo 'PASS report: 決める記録を書いたあとに読めない候補が現れたら、decide を流さず、決める記録を残して知らせを書く'
