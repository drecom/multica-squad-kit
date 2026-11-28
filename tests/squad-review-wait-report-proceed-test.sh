#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-wait-report-proceed-test.sh で実行する。
# この部分は、読み直しと投稿の失敗、proceed の判定を確認する。
# CLI を差し替え、実際のタスク・規則・エージェントには書き込まない。report と proceed の知らせ・次へ回す記録を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

source "$root/tests/review-wait-test-lib.sh"

round_ts=$((now - 120))
round_time=$(jq -nr --argjson ts "$round_ts" '$ts | todateiso8601')
both='result:a:r1:5 result:b:r2:6'
own_record='decide:a:posted-2:90'

# 結果投稿後の失敗は、未返答とは区別して返す。結果は再投稿しない。決める実行は流さない。
# 2 回目の取得は結果の投稿直後、3 回目は決める記録の投稿後の読み直し。
for read_at in 2 3; do
	for failure in cli json round; do
		reset_calls
		build_comments $both >"$test_dir/comments.json"
		case $failure in
		cli) echo "$read_at" >"$test_dir/fail-list-at" ;;
		json) printf 'invalid json' >"$test_dir/comments.$read_at.json" ;;
		round) jq '.[0].content = null' "$test_dir/comments.json" >"$test_dir/comments.$read_at.json" ;;
		esac
		if bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
		[[ -s $test_dir/error && ! -s $test_dir/output && $(list_count) == "$read_at" && -z $(decide_calls) && -z $(slept) ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
		if [[ $failure == cli ]]; then [[ $(<"$test_dir/error") == 'CLI mock comment list failure' ]]; fi
		assert_jq -s --argjson n "$((read_at - 1))" 'length == $n and .[0].body == "/note\nqa result\n返事の回: round\n"' "$test_dir/posted.jsonl"
		echo "PASS report: 読み直し ${read_at} 回目の ${failure} 失敗を返し、結果を再投稿せず、決めない"
	done
done

# 決める記録の投稿の失敗と、知らせの投稿の失敗も、そのまま返す。再投稿しない。
reset_calls
build_comments $both >"$test_dir/comments.json"
echo 2 >"$test_dir/fail-add-at"
if bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ $(<"$test_dir/error") == 'CLI mock comment add failure' && ! -s $test_dir/output && $(list_count) == 2 && -z $(decide_calls) && -z $(slept) ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
assert_jq -s 'length == 1 and .[0].body == "/note\nqa result\n返事の回: round\n"' "$test_dir/posted.jsonl"
assert_jq -s '[.[] | select(.[0:3] == ["issue", "comment", "add"])] | length == 2' "$test_dir/calls.jsonl"
echo 'PASS report: 決める記録の投稿の失敗を返し、再投稿せず、決めない'

reset_calls
build_comments $both >"$test_dir/comments.1.json"
cp "$test_dir/comments.1.json" "$test_dir/comments.2.json"
build_comments $both $own_record >"$test_dir/comments.json"
echo 3 >"$test_dir/decide-status"
printf '次の依頼を決められません: テスト\n' >"$test_dir/decide-out"
echo 3 >"$test_dir/fail-add-at"
if bash "$script" report test-issue trigger "$test_dir/result.md" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ $(<"$test_dir/error") == 'CLI mock comment add failure' && ! -s $test_dir/output && $(decide_calls) == 'decide test-issue round' ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
assert_jq -s 'length == 2' "$test_dir/posted.jsonl"
echo 'PASS report: 知らせの投稿の失敗を返し、再投稿しない'

# proceed: 知らせがなければ、拾い直しの知らせと記録を書き、いちばん早い記録なので進む。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:posted-1:90 claim:orch:posted-2:91 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue watch-trigger)
[[ $output == '返事の待ち: 次に進む' && $(slept) == 20 && $(deleted_rules) == 2 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
assert_jq -s 'length == 2 and all(.[]; .args | index("--parent") as $i | .[$i+1] == "watch-trigger")
	and (.[0].body | startswith("返事がそろいました（見張りで拾い直しました）。\n\n待っていた役の結果が、すべてそろいました。\n\n返した役:\n"))
	and (.[0].body | contains("mention://") | not)
	and .[1].body == "/note\n返事の待ち: この回を次へ回します\n"' "$test_dir/posted.jsonl"
echo 'PASS proceed: 知らせがなければ拾い直しの知らせと記録を書き、見張りを消して次に進む'

# proceed: 知らせで起きた実行は、記録だけを書いて進む。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:posted-1:8 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue k1)
[[ $output == '返事の待ち: 次に進む' && $(posted_ready_count) == 0 && $(posted_claim_count) == 1 && $(slept) == 20 && $(deleted_rules) == 2 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
echo 'PASS proceed: 知らせで起きた実行は、記録だけを書いて次に進む'

# proceed: 1 回目は次に進み、記録が残った 2 回目は書かず、待たずに回ごと済み。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:posted-1:8 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue k1)
[[ $output == $'/note\n返事の待ち: 回ごと済み' && ! -s $test_dir/posted.jsonl && -z $(slept) && $(deleted_rules) == 0 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
echo 'PASS proceed: 記録が残った回では、書かずに回ごと済み'

# proceed: 4 個の囲みの中の 3 個の囲みの例にある次へ回す記録は、記録と数えない。書いて進む。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:posted-1:9 \
	| with_raw example orchestrator agent 8 "$(printf '````\n```\n/note\n返事の待ち: この回を次へ回します\n```\n````')" >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue k1)
[[ $output == '返事の待ち: 次に進む' && $(posted_claim_count) == 1 && $(slept) == 20 && $(deleted_rules) == 2 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
echo 'PASS proceed: 4 個の囲みの中の例にある次へ回す記録は数えず、記録を書いて次に進む'

# proceed: 字下げ 4 個の終了風の行は囲みを閉じないので、その後ろの次へ回す記録も記録と数えない。書いて進む。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:posted-1:9 \
	| with_raw example orchestrator agent 8 "$(printf '/note\n```\n    ```\n返事の待ち: この回を次へ回します\n```')" >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue k1)
[[ $output == '返事の待ち: 次に進む' && $(posted_claim_count) == 1 && $(slept) == 20 && $(deleted_rules) == 2 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
echo 'PASS proceed: 字下げ 4 個の終了風の行のあとの次へ回す記録は数えず、記録を書いて次に進む'

# proceed: 2 つの実行がほぼ同時に記録を書いたら、進むのは早い記録の実行だけ。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:c0:8 claim:orch:posted-1:9 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue k1)
[[ $output == $'/note\n返事の待ち: 回ごと済み' && $(deleted_rules) == 0 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
echo 'PASS proceed: 記録が重なったら、早い記録の実行だけが進む'

# proceed: 同じ時刻の記録は ID の順で選ぶ。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:posted-1:8 claim:orch:zz:8 >"$test_dir/comments.json"
[[ $(bash "$script" proceed test-issue k1) == '返事の待ち: 次に進む' ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:posted-1:8 claim:orch:a0:8 >"$test_dir/comments.json"
[[ $(bash "$script" proceed test-issue k1) == $'/note\n返事の待ち: 回ごと済み' ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
echo 'PASS proceed: 同じ時刻の記録は ID の順'

# proceed: 書いた記録が 2 回とも見えなければ、ID を添えて失敗する。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.json"
if bash "$script" proceed test-issue k1 >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output && $(<"$test_dir/error") == *'posted-1'* && $(slept) == '20,20' && $(list_count) == 3 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
[[ $(posted_claim_count) == 1 && $(deleted_rules) == 0 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
echo 'PASS proceed: 記録が 2 回とも見えなければ、ID を添えて失敗する'

# proceed: 返していない役がいる回と、回がないときは何もしない。
reset_calls
build_comments result:a:r1:5 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue watch-trigger)
[[ $output == $'/note\n返事の待ち: 返っていない役がいるので何もしない' && ! -s $test_dir/posted.jsonl && -z $(slept) && $(deleted_rules) == 0 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
printf '[]' >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue watch-trigger)
[[ $output == $'/note\n返事の待ち: 回がないので何もしない' && -z $(slept) ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
echo 'PASS proceed: 返していない役がいる回と回なしでは何もしない'

# proceed: 待つ間に新しい回が書かれたら、前の回の知らせでは進まない。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
# build_comments は comments.json を書いて読むので、同じファイルへのリダイレクトとパイプでつながない。
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.base.json"
jq --slurpfile comment "$test_dir/comment-prototype.json" --arg a "$a" --arg time "$(jq -nr --argjson ts "$((round_ts + 30))" '$ts | todateiso8601')" \
	'. + [$comment[0] + {id: "round2", author_type: "agent", author_id: "orchestrator", created_at: $time, content: ("返事を待つ役: [@review](mention://agent/" + $a + ")")}]' "$test_dir/comments.base.json" >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue k1)
[[ $output == $'/note\n返事の待ち: 新しい回があるので何もしない' && $(deleted_rules) == 0 && $(posted_claim_count) == 1 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
echo 'PASS proceed: 待つ間に新しい回が書かれたら何もしない'

# proceed: CLI の失敗では、進むと答えずにエラー。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:k1:7 claim:orch:posted-1:8 >"$test_dir/comments.json"
printf 'issue wakeup list' >"$test_dir/fail"
if bash "$script" proceed test-issue k1 >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
rm "$test_dir/fail"
echo 'PASS proceed: CLI 失敗では次に進むと答えずエラー'

# proceed: 決める記録から 15 分たっていなければ、知らせがなくても、決める実行の途中なので何も書かず、見張りも消さない。
reset_calls
build_comments $both decide:a:d1:90 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue watch-trigger)
[[ $output == $'/note\n返事の待ち: スクリプトが次の依頼を決めている' && ! -s $test_dir/posted.jsonl && -z $(slept) && $(deleted_rules) == 0 && $(list_count) == 1 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
output=$(REVIEW_WAIT_TEST_NOW=$((now + 869)) bash "$script" proceed test-issue watch-trigger)
[[ $output == $'/note\n返事の待ち: スクリプトが次の依頼を決めている' && ! -s $test_dir/posted.jsonl ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
echo 'PASS proceed: 決める記録から 15 分たっていなければ、何も書かずに待つ'

# proceed: 決める記録から 15 分以上たち、知らせがなければ、拾い直しの知らせと次へ回す記録を書いて進む。
# 決める記録は、次へ回す記録として数えない。自分の記録だけが次へ回す記録になる。
reset_calls
build_comments $both decide:a:d1:90 >"$test_dir/comments.1.json"
build_comments $both decide:a:d1:90 ready:orch:posted-1:91 claim:orch:posted-2:92 >"$test_dir/comments.json"
output=$(REVIEW_WAIT_TEST_NOW=$((now + 870)) bash "$script" proceed test-issue watch-trigger)
[[ $output == '返事の待ち: 次に進む' && $(posted_ready_count) == 1 && $(posted_claim_count) == 1 && $(posted_decide_count) == 0 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
echo 'PASS proceed: 15 分以上たった決める記録は拾い直しを止めず、自分の次へ回す記録だけが数えられる'

# proceed: 決める記録が新しくても、そろった知らせがあれば（決められなかった回）、次へ回す記録を書いて進む。
reset_calls
build_comments $both decide:a:d1:90 ready:orch:k1:95 >"$test_dir/comments.1.json"
build_comments $both decide:a:d1:90 ready:orch:k1:95 claim:orch:posted-1:96 >"$test_dir/comments.json"
output=$(bash "$script" proceed test-issue k1)
[[ $output == '返事の待ち: 次に進む' && $(posted_ready_count) == 0 && $(posted_claim_count) == 1 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
echo 'PASS proceed: 決める記録が新しくても、知らせで起きた実行は次へ回す記録を書いて進む'

# proceed: 次の依頼が書かれた回（前の回で回を指すコメントがある）は、決める記録の経過によらず、何も書かずに回ごと済み。
reset_calls
build_comments $both decide:a:d1:90 next:orch:n1:95 >"$test_dir/comments.json"
for at in "$now" $((now + 870)); do
	output=$(REVIEW_WAIT_TEST_NOW=$at bash "$script" proceed test-issue watch-trigger)
	[[ $output == $'/note\n返事の待ち: 回ごと済み' && ! -s $test_dir/posted.jsonl && $(deleted_rules) == 0 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
done
echo 'PASS proceed: 次の依頼が書かれた回は、何も書かずに回ごと済み'

# proceed: 引用は読めない書き方で、回を指す候補になる。回ごと済みにも次に進むにもせず、理由を出して終了 1 になり、何も書かない。
reset_calls
build_comments result:a:r1:5 result:b:r2:6 | with_raw n-q orchestrator agent 8 $'> 修正の依頼: 直してください\n> 前の回: round' >"$test_dir/comments.1.json"
build_comments result:a:r1:5 result:b:r2:6 ready:orch:posted-1:90 claim:orch:posted-2:91 | with_raw n-q orchestrator agent 8 $'> 修正の依頼: 直してください\n> 前の回: round' >"$test_dir/comments.json"
if bash "$script" proceed test-issue watch-trigger >"$test_dir/output" 2>"$test_dir/error"; then echo "引用の候補で止まらなかった: $(<"$test_dir/output")" >&2; exit 1; fi
[[ $(<"$test_dir/error") == *'制御記録を読めない（n-q: 1 行目: 引用）'* && ! -s $test_dir/posted.jsonl && $(deleted_rules) == 0 ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認: $(<"$test_dir/error")" >&2; exit 1; }
echo 'PASS proceed: 引用の前の回: は読めない候補で、何も書かずに終了 1 になる'

# proceed: 制御記録でない `前の回:`（役の結果、人間のコメント、種類の行のないコメント）では、回ごと済みにせず次に進む。
for spec in "r|$a|agent|/note"$'\n'"返事の回: round"$'\n'"前の回: round" \
	"h|human-1|member|修正の依頼: 直してください"$'\n'"前の回: round" \
	"b|orchestrator|agent|次の依頼です"$'\n'"前の回: round"; do
	IFS='|' read -r id who type body <<<"$(printf '%s' "$spec" | tr '\n' '\001')"
	body=$(printf '%s' "$body" | tr '\001' '\n')
	reset_calls
	build_comments result:a:r1:5 result:b:r2:6 | with_raw "n-$id" "$who" "$type" 8 "$body" >"$test_dir/comments.1.json"
	build_comments result:a:r1:5 result:b:r2:6 ready:orch:posted-1:90 claim:orch:posted-2:91 | with_raw "n-$id" "$who" "$type" 8 "$body" >"$test_dir/comments.json"
	output=$(bash "$script" proceed test-issue watch-trigger)
	[[ $output == '返事の待ち: 次に進む' ]] || { echo "回ごと済みにした: $id → $output" >&2; exit 1; }
done
echo 'PASS proceed: 結果・人間・種類のない前の回: だけでは、回ごと済みにしない'
