#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-requirement-test.sh で実行する。
# squad-review-next decide の判定のうち、要件の見直しの回（PR がない回、見直さずに返った結果、実際の report）を確認する。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
reset

# ---- 要件の見直しの回は、確認する対象がタスクの本文の sha256 で PR がなくても、返事の中身によらず書かず、PR の見張りも呼ばずにリーダーに任せる。
body_hash=$(printf '%s' '要件の本文' | shasum -a 256 | cut -d' ' -f1)
for reply in '✅ 指摘なし|なし' '⚠️ 要件の指摘|なし'; do
	reset
	add round-1 orchestrator $'見直しの種類: 要件の見直し\n確認するコミット: タスクの本文 '"$body_hash"$'\n返事を待つ役: '"$(mentions claude-principal)"
	result round-1 claude-principal "${reply%%|*}" "$body_hash" "${reply##*|}"
	run round-1
	expect_leader '要件の見直しの回はリーダーが扱う'
	expect_nothing_written
	expect_no_calls pr-watch-calls
done
reset
add round-1 orchestrator $'見直しの種類: 要件の見直し\n確認するコミット: タスクの本文 '"$body_hash"$'\n返事を待つ役: '"$(mentions claude-principal)"
run round-1
expect_leader '要件の見直しの回はリーダーが扱う'
echo 'PASS review-next-decide: 要件の見直しの回は、PR がなくても返事の中身によらず、書かず PR の見張りも呼ばずにリーダーに任せる'
# 見直さずに返った結果（確認したコミット: なし、❌）も、同じ道でリーダーに返り、何も書かず PR の見張りも呼ばない。
for why in '複数のリポジトリにまたがるが sub-issue がない' 'sub-issue の repository がないか一覧にない: demo-sub' 'checkout できない: example/demo'; do
	reset
	add round-1 orchestrator $'見直しの種類: 要件の見直し\n確認するコミット: タスクの本文 '"$body_hash"$'\n返事を待つ役: '"$(mentions claude-principal)"
	result round-1 claude-principal ❌ "なし（${why}）" なし
	run round-1
	expect_leader '要件の見直しの回はリーダーが扱う'
	expect_nothing_written
	expect_no_calls pr-watch-calls
done
echo 'PASS review-next-decide: 見直さずに返った要件の見直しの ❌ も、書かず PR の見張りも呼ばずにリーダーに任せる'

# 見直さずに返った結果を、実際の squad-review-wait report で返す。report が結果を書き、決める記録を書き、decide を経て、
# 何も依頼を書かず PR の見張りも呼ばずに、リーダーへの知らせだけを書く。投稿はコメントの一覧に足されるので、report の読み直しも通る。
cp "$test_dir/monitor/squad-review-wait" "$test_dir/monitor/squad-review-wait.stub"
cp "$root/common/monitor/squad-review-wait" "$test_dir/monitor/squad-review-wait"
cat >"$test_dir/bin/sleep" <<'EOF2'
#!/usr/bin/env bash
echo "$1" >>"$REVIEW_NEXT_TEST_DIR/sleeps.log"
EOF2
chmod +x "$test_dir/bin/sleep"
for why in '複数のリポジトリにまたがるが sub-issue がない' 'sub-issue の repository がないか一覧にない: demo-sub' 'checkout できない: example/demo'; do
	reset
	: >"$test_dir/sleeps.log"
	add round-1 orchestrator $'見直しの種類: 要件の見直し\n確認するコミット: タスクの本文 '"$body_hash"$'\n返事を待つ役: '"$(mentions claude-principal)"
	echo claude-principal >"$test_dir/report-author"
	# 役の指示どおりの結果のファイル。/note と返事の回の行は report が足す。
	printf '確認したコミット: なし（%s）\n❌ demo-claude-principal-test: 見直さずに返します\n設計への指摘: なし\n' "$why" >"$test_dir/principal-result.md"
	status=0
	(cd "$test_dir" && bash monitor/squad-review-wait report test-issue round-1 principal-result.md) >"$test_dir/out" 2>"$test_dir/err" || status=$?
	[[ $status == 0 ]] || fail "report が失敗した（$status）: $(<"$test_dir/err")"
	# 投稿は 3 件: 結果、決める記録、決められないという知らせ。依頼・状態の変更・見張りは書かない。
	[[ $(jq -s length "$test_dir/posted.jsonl") == 3 ]] || fail "投稿が 3 件でない: $(<"$test_dir/posted.jsonl")"
	jq -s -e --arg commit "確認したコミット: なし（${why}）" \
		'.[0].body == "/note\n" + $commit + "\n❌ demo-claude-principal-test: 見直さずに返します\n設計への指摘: なし\n返事の回: round-1\n"
		and .[1].body == "/note\n返事の待ち: 次の依頼を決めます\n"
		and (.[2].body | startswith("[@DEMO-TEST](mention://squad/squad-test) 返事がそろいました。\n次の依頼を決められません: 要件の見直しの回はリーダーが扱う\n"))
		and (.[2].body | contains("mention://agent/") | not)
		and all(.[]; .args | index("--parent") as $i | .[$i + 1] == "round-1")' "$test_dir/posted.jsonl" >/dev/null \
		|| fail "report が書いたコメントが違う: $(<"$test_dir/posted.jsonl")"
	expect_no_calls pr-watch-calls
	expect_no_calls watch-calls
	expect_no_calls pick-calls
	expect_no_calls status-calls
	[[ ! -s $test_dir/sleeps.log ]] || fail "待ってはいけない: $(<"$test_dir/sleeps.log")"
done
rm -f "$test_dir/bin/sleep"
mv "$test_dir/monitor/squad-review-wait.stub" "$test_dir/monitor/squad-review-wait"
echo 'PASS review-next-decide: 見直さずに返った要件の見直しの ❌ を実際の report で返すと、結果と決める記録と知らせだけを書き、PR の見張りも依頼も呼ばない'
