#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-wait-report-test.sh で実行する。
# この部分は、返事がそろった回の読み方と、決める記録の書き方・重なり・読み直しを確認する。
# CLI を差し替え、実際のタスク・規則・エージェントには書き込まない。report と proceed の知らせ・次へ回す記録を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

source "$root/tests/review-wait-test-lib.sh"

round_ts=$((now - 120))
round_time=$(jq -nr --argjson ts "$round_ts" '$ts | todateiso8601')
both='result:a:r1:5 result:b:r2:6'
own_record='decide:a:posted-2:90'

# /note 付きとふつうのコメントで返した 2 役がそろい、知らせがない回を拾い直す。
reset_calls
build_comments result:a:r1:5 plain-result:b:r2:6 >"$test_dir/comments.json"
printf '[]' >"$test_dir/runs.json"
check_status '返事の待ち: 返事がそろっていて、まだ次へ回していない'
[[ ! -s $test_dir/posted.jsonl ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
echo 'PASS status: /note 付きとふつうのコメントで返した回も、知らせがなければ拾い直す'

# 同じ状態で proceed を流すと、拾い直しの知らせと次へ回す記録を 1 つずつ書いて進む。
reset_calls
build_comments result:a:r1:5 plain-result:b:r2:6 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 plain-result:b:r2:6 ready:orch:posted-1:90 claim:orch:posted-2:91 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue r2)
[[ $output == '返事の待ち: 次に進む' && $(posted_ready_count) == 1 && $(posted_claim_count) == 1 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
assert_jq -s 'length == 2 and (.[0].body | startswith("返事がそろいました（見張りで拾い直しました）。\n"))' "$test_dir/posted.jsonl"
echo 'PASS proceed: /note 付きとふつうのコメントの回を拾い直し、知らせを 1 つ書いて次に進む'

# 同じ秒に始まる形: 2 役が回と同じ秒に始まり、返した役のほかに失敗した役がいる。
reset_calls
build_comments result:a:r1:5 >"$test_dir/comments.json"
for state in failed cancelled; do
	{
		run_fixture "$a" completed "$round_ts"
		run_fixture "$b" "$state" "$round_ts" '利用上限'
	} | jq -s 'map(. + {trigger_comment_id: "round"})' >"$test_dir/runs.json"
	check_status "返事の待ち: 人間を呼ぶ"$'\n'"- demo-qa-test: ${state}（利用上限）"
done
echo 'PASS status: 同じ秒に始まった 2 役のうち、返した役を除いて失敗・取り消しの役だけを人間へ'

# 返した役がいても、同じ秒の前の回の失敗では人間を呼ばない。
{
	run_fixture "$a" completed "$round_ts" | jq '. + {trigger_comment_id: "round"}'
	run_fixture "$b" failed "$round_ts" | jq '. + {trigger_comment_id: "previous-round"}'
} | jq -s '.' >"$test_dir/runs.json"
check_status $'/note\n返事の待ち: 返っていない役は待ちか実行中なので何もしない'
echo 'PASS status: 同じ秒に始まった役が返し済みでも、前の回の失敗を除外'

# すぐの読み直しでそろったときは、結果、同じ役の決める記録、決めるスクリプトの順に進む。知らせは書かない。
# 取得の順は、1 回目が結果の投稿前、2 回目が結果の投稿後、3 回目が決める記録の投稿後の読み直し。

reset_calls
build_comments $both >"$test_dir/comments.1.json"
cp "$test_dir/comments.1.json" "$test_dir/comments.2.json"
build_comments $both $own_record >"$test_dir/comments.json"
bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(list_count) == 3 && -z $(slept) && $(posted_ready_count) == 0 && $(posted_decide_count) == 1 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
[[ $(decide_calls) == 'decide test-issue round' && $(<"$test_dir/decide-posted-at") == 2 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
assert_jq -s 'length == 2 and .[0].body == "/note\nqa result\n返事の回: round\n" and .[1].body == "/note\n返事の待ち: 次の依頼を決めます\n"' "$test_dir/posted.jsonl"
assert_jq -s 'all(.[]; .args | index("--parent") as $i | .[$i+1] == "trigger")' "$test_dir/posted.jsonl"
echo 'PASS report: 結果、同じ役の決める記録、決めるスクリプトの順に進み、知らせは書かない'

# 役が `返事の回:` の行を書いていても、スクリプトが付ける 1 行だけにする。/note のない結果には /note を足す。
reset_calls
printf '確認したコミット: abc\n返事の回: other\n結果です' >"$test_dir/plain-result.md"
build_comments $both ready:orch:k1:7 >"$test_dir/comments.json"
bash "$script" report test-issue trigger "$test_dir/plain-result.md"
assert_jq -s '.[0].body == "/note\n確認したコミット: abc\n結果です\n返事の回: round\n"' "$test_dir/posted.jsonl"
echo 'PASS report: 返事の回の行は、スクリプトが 1 行だけ付ける'

# すぐの読み直しで相手が見えず、待ってからの読み直しで見えたときは、そこで決める記録を書いて決める。
reset_calls
build_comments result:a:r1:5 >"$test_dir/comments.1.json"
cp "$test_dir/comments.1.json" "$test_dir/comments.2.json"
build_comments $both >"$test_dir/comments.3.json"
build_comments $both $own_record >"$test_dir/comments.json"
bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(slept) == 20 && $(list_count) == 4 && $(posted_decide_count) == 1 && $(decide_calls) == 'decide test-issue round' ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
echo 'PASS report: 待ってからの読み直しで相手が見えれば、決める記録を書いて決める'

# 待っても返していない役がいれば、記録も知らせも書かず、決めない。読み直しは 1 回だけ。待つ秒数は REVIEW_WAIT_RECHECK_SECONDS に従う。
reset_calls
build_comments result:a:r1:5 >"$test_dir/comments.json"
bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(slept) == 20 && $(list_count) == 3 && $(jq -s length "$test_dir/posted.jsonl") == 1 && -z $(decide_calls) ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
REVIEW_WAIT_RECHECK_SECONDS=7 bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(slept) == 20,7 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
echo 'PASS report: 待っても返していない役がいれば何も書かず決めない。待つ秒数は REVIEW_WAIT_RECHECK_SECONDS に従う'

# すでに知らせ・次の依頼・次へ回す記録・ほかの実行の決める記録があれば、決める記録を書かず、決めず、待たない。
for existing in ready:orch:k1:7 next:orch:n1:7 claim:orch:c1:7 decide:b:d1:7; do
	reset_calls
	build_comments $both "$existing" >"$test_dir/comments.json"
	bash "$script" report test-issue trigger "$test_dir/result.md"
	[[ $(jq -s length "$test_dir/posted.jsonl") == 1 && -z $(decide_calls) && -z $(slept) && $(list_count) == 2 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
done
echo 'PASS report: 知らせ・次の依頼・次へ回す記録・ほかの決める記録があれば、記録を書かず決めない'

# 決める記録が重なったら、決めるのは最も早い記録の実行だけ。同じ時刻は ID の順。
for race in decide:b:other:80:0 decide:b:other:95:1 decide:b:a0:90:0 decide:b:zz:90:1; do
	IFS=: read -r kind who id sec expect <<<"$race"
	reset_calls
	build_comments $both >"$test_dir/comments.1.json"
	cp "$test_dir/comments.1.json" "$test_dir/comments.2.json"
	build_comments $both $own_record "$kind:$who:$id:$sec" >"$test_dir/comments.json"
	bash "$script" report test-issue trigger "$test_dir/result.md"
	[[ $(posted_decide_count) == 1 && $(jq -s length "$test_dir/posted.jsonl") == 2 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
	if [[ $expect == 1 ]]; then [[ $(decide_calls) == 'decide test-issue round' ]]; else [[ -z $(decide_calls) ]]; fi
done
echo 'PASS report: 決める記録が重なったら、最も早い記録の実行だけが決める（同じ時刻は ID の順）'

# 記録を書いたあとに、次の依頼や次へ回す記録が見えたら、決めない。
for later in next:orch:n1:95 claim:orch:c1:95; do
	reset_calls
	build_comments $both >"$test_dir/comments.1.json"
	cp "$test_dir/comments.1.json" "$test_dir/comments.2.json"
	build_comments $both $own_record "$later" >"$test_dir/comments.json"
	bash "$script" report test-issue trigger "$test_dir/result.md"
	[[ -z $(decide_calls) && $(jq -s length "$test_dir/posted.jsonl") == 2 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
done
echo 'PASS report: 記録のあとに次の依頼や次へ回す記録が見えたら決めない'

# 自分の決める記録が読み直しで見えなければ、待って読み直し、見えたら決める。2 回待っても見えなければ、ID を添えて失敗する。
reset_calls
for n in 1 2 3; do build_comments $both >"$test_dir/comments.$n.json"; done
build_comments $both $own_record >"$test_dir/comments.json"
bash "$script" report test-issue trigger "$test_dir/result.md"
[[ $(slept) == 20 && $(list_count) == 4 && $(decide_calls) == 'decide test-issue round' && $(posted_decide_count) == 1 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
reset_calls
build_comments $both >"$test_dir/comments.json"
if bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output && $(<"$test_dir/error") == '決める記録が読み直しで見えません: コメント posted-2' && $(slept) == '20,20' && $(list_count) == 5 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
[[ $(posted_decide_count) == 1 && -z $(decide_calls) ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
echo 'PASS report: 自分の決める記録が見えなければ待って読み直し、2 回待っても見えなければ ID を添えて失敗する'

# 決められないとき（終了コード 3）は、理由を 2 行目に置いた知らせで、スクワッドのリーダーを起こす。
# 設計の見直しの回は、結果が ✅ でもコードの指摘でも、決める側が理由つきで決められないと返す。report は結果の中身を見ない。
for reason in '設計の見直しの回はリーダーが扱う' '設計への指摘: あり（設計のずれ）' '最上位の役の結果がタスクにない'; do
	reset_calls
	build_comments $both >"$test_dir/comments.1.json"
	cp "$test_dir/comments.1.json" "$test_dir/comments.2.json"
	build_comments $both $own_record >"$test_dir/comments.json"
	printf '次の依頼を決められません: %s\n' "$reason" >"$test_dir/decide-out"
	echo 3 >"$test_dir/decide-status"
	bash "$script" report test-issue trigger "$test_dir/result.md"
	[[ $(posted_ready_count) == 1 && $(jq -s length "$test_dir/posted.jsonl") == 3 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
	jq -s -e --arg reason "$reason" '.[2].body == "[@demo-squad](mention://squad/squad-test) 返事がそろいました。\n次の依頼を決められません: " + $reason + "\n\n待っていた役の結果が、すべてそろいました。\n\n返した役:\n- demo-code-reviewer-test\n- demo-qa-test\n"
		and (.[2].body | contains("mention://agent/") | not)
		and (.[2].args | index("--parent") as $i | .[$i+1] == "trigger")' "$test_dir/posted.jsonl" >/dev/null
done
echo 'PASS report: 決められないときは、理由の行を足した知らせでスクワッドのリーダーを起こす'
