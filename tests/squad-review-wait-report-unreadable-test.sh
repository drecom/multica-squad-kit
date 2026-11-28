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
