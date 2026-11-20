#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-request-test.sh で実行する。
# squad-review-next-test.sh の後半: 名前を変えたファイル、一覧を読めない場合、名簿にない役、失敗の出し方、修正の依頼の範囲。
# 共通の準備は tests/review-next-test-lib.sh。実際のタスク・PR・エージェントには書き込まない。
source "$(dirname "$0")/review-next-test-lib.sh"
reset

# ---- 名前を変えたファイルは、前の名前と新しい名前の両方を当てる。消したファイルも当てる。
reset
set_files src/run.sh:docs/run.md
run
expect_request code-reviewer '変えたファイル 1 件が対応に当たった（プロジェクト 0 件・既定 1 件）'
reset
set_files src/run.sh:web/run.tsx
run
expect_request 'code-reviewer、ux-reviewer、qa' '変えたファイル 1 件が対応に当たった（プロジェクト 0 件・既定 1 件）'
reset
set_files src/run.sh:data/old.bin
run
expect_request "$all" '対応に当たらないファイルが 1 件あるため、有効な観点をすべて頼む'
reset
set_files data/new.bin:src/old.sh
run
expect_request "$all" '対応に当たらないファイルが 1 件あるため、有効な観点をすべて頼む'
reset
fixture gh-pr-files | jq '[. + {filename: "web/Old.tsx", status: "removed"}]' >"$test_dir/files.json"
run
expect_request 'code-reviewer、ux-reviewer、qa' '変えたファイル 1 件が対応に当たった（プロジェクト 0 件・既定 1 件）'
echo 'PASS review-next: 名前を変えたファイルは前後の名前の両方を当て、消したファイルも当てる'

# ---- ファイルの一覧を読めない、または切れているときは、有効な観点をすべて頼む。
reset
touch "$test_dir/files-fail"
run
expect_request "$all" "$(all_reason '変えたファイルの一覧を読めない')"
reset
fixture gh-pr-files | jq '[range(3000) as $n | . + {filename: "src/file\($n).sh"}]' >"$test_dir/files.json"
run
expect_request "$all" "$(all_reason '変えたファイルの一覧が GitHub の上限で切れている')"
echo 'PASS review-next: ファイルの一覧を読めない、または上限で切れているときは、有効な観点をすべて頼む'

# ---- 名簿にない役は頼まない。選んだ観点と有効な観点の重なりが空なら、有効な観点をすべて頼む。
reset
set_roster orchestrator code-reviewer qa
set_issue_labels label-imp
run
expect_request 'code-reviewer、qa' 'マーク「重要」があるため、有効な観点をすべて頼む'
reset
set_roster orchestrator code-reviewer qa
set_files web/App.tsx src/auth/login.py
run
expect_request 'code-reviewer、qa' '変えたファイル 2 件が対応に当たった（プロジェクト 0 件・既定 2 件）'
reset
set_roster orchestrator qa
set_files README.md
run
expect_request qa '対応で選んだ観点が有効な観点にないため、有効な観点をすべて頼む'
echo 'PASS review-next: 名簿にある役だけを有効な観点とし、重なりが空なら有効な観点をすべて頼む'

# ---- 失敗したときは、依頼を書かずに標準エラーへ要約を出す。
reset
echo 1 >"$test_dir/watch-status"
run
expect_status 1
expect_no_comment
grep -q '依頼を書けません' "$test_dir/err"
[[ ! -s $test_dir/out ]]
reset
touch "$test_dir/post-fail"
run
expect_status 1
grep -q 'コメントの投稿に失敗した' "$test_dir/err"
[[ ! -s $test_dir/out ]]
# 見張りを入れたあとに投稿に失敗したら、見張りを消す。
[[ $(<"$test_dir/watch-calls") == "watch test-issue trigger-1 "*$'\nunwatch test-issue' ]] || fail "投稿の失敗で見張りを消していない: $(<"$test_dir/watch-calls")"
reset
set_roster orchestrator claude-implementer
run
expect_status 1
expect_no_comment
[[ ! -s $test_dir/watch-calls ]]
grep -q 'レビューと E2E の役がない' "$test_dir/err"
reset
touch "$test_dir/labels-fail"
run
expect_status 1
expect_no_comment
[[ ! -s $test_dir/watch-calls ]]
reset
jq '.metadata.pr_url = ""' "$test_dir/issue.base.json" >"$test_dir/issue.json"
run
expect_status 1
expect_no_comment
grep -q 'PR を決められない' "$test_dir/err"
reset
jq '.metadata.repository = "demo/other"' "$test_dir/issue.base.json" >"$test_dir/issue.json"
run
expect_status 1
expect_no_comment
reset
status=0
(cd "$test_dir" && bash monitor/squad-review-next request test-issue trigger-1 abc123) >"$test_dir/out" 2>"$test_dir/err" || status=$?
expect_status 1
expect_no_comment
grep -q '完全な SHA' "$test_dir/err"
status=0
(cd "$test_dir" && bash monitor/squad-review-next request test-issue) >"$test_dir/out" 2>"$test_dir/err" || status=$?
expect_status 2
status=0
(cd "$test_dir" && bash monitor/squad-review-next decide test-issue) >"$test_dir/out" 2>"$test_dir/err" || status=$?
expect_status 2
grep -q '使い方' "$test_dir/err"
echo 'PASS review-next: 見張りが入らない、投稿に失敗する、役がない、タスクを読めない、PR を決められない、SHA が不正なときは、依頼を書かず標準エラーに理由を出して終わる'

# ---- 列挙の行。最新の修正の依頼だけを読み、名前と行の順を保って PR の行の後ろに足す。
add_comment() {
	local base
	base=$(fixture issue-comments agent)
	jq --argjson base "$base" --arg id "$1" --arg at "$2" --arg text "$3" 		'. + [$base + {id: $id, author_id: "orchestrator", created_at: $at, content: $text}]' 		"$test_dir/comments.json" >"$test_dir/comments.new"
	mv "$test_dir/comments.new" "$test_dir/comments.json"
}
reason='変えたファイル 1 件が対応に当たった（プロジェクト 0 件・既定 1 件）'
reset
add_comment fix-latest 2026-11-10T12:02:00Z $'/note 修正の依頼: 2 回目\r\n頼む範囲: 種類単位（src/cart/Badge.tsx:formatCount）\r\n頼む範囲: 種類単位（src/別の部品.ts:規則 A）'
add_comment fix-old 2026-11-10T12:01:00Z $'修正の依頼: 1 回目\n頼む範囲: 種類単位（古い部品）'
run
expect_request code-reviewer "$reason" $'列挙を頼む部品: src/cart/Badge.tsx:formatCount\n列挙を頼む部品: src/別の部品.ts:規則 A'
# 最新の依頼に範囲がなければ、古い範囲を持ち越さない。
add_comment fix-next 2026-11-10T12:03:00Z '修正の依頼: 3 回目'
: >"$test_dir/posted.jsonl"; : >"$test_dir/watch-calls"
run
expect_request code-reviewer "$reason"
# 修正の依頼がない範囲の行、囲みの中の修正の依頼は使わない。
reset
add_comment note 2026-11-10T12:01:00Z $'頼む範囲: 種類単位（部品）\n```text\n修正の依頼: 1 回目\n```'
run
expect_request code-reviewer "$reason"
# 修正の依頼のあとにレビューの回があれば足さない。前の回だけなら足す。
reset
add_comment fix 2026-11-10T12:02:00Z $'修正の依頼: 2 回目\n頼む範囲: 種類単位（部品）'
add_comment review-old 2026-11-10T12:01:00Z '返事を待つ役: reviewer'
run
expect_request code-reviewer "$reason" '列挙を頼む部品: 部品'
add_comment review-new 2026-11-10T12:03:00Z '返事を待つ役: reviewer'
: >"$test_dir/posted.jsonl"; : >"$test_dir/watch-calls"
run
expect_request code-reviewer "$reason"
echo 'PASS review-next: 最新の修正の依頼の範囲を同じ順で写し、範囲なし・依頼なし・再確認済みでは足さない'
# 読めないコメントと、選んだ依頼の形の違う範囲は、見張りも投稿もしない。
for scope in '頼む範囲: 種類単位' '頼む範囲: 個別（部品）' '頼む範囲: 種類単位（）'; do
	reset
	add_comment fix 2026-11-10T12:01:00Z $'修正の依頼: 2 回目\n'"$scope"
	run
	expect_status 1
	expect_no_comment
	[[ ! -s $test_dir/watch-calls ]] || fail '不正な範囲で見張りを入れた'
	grep -qF '頼む範囲: の行の形が違う' "$test_dir/err"
done
reset
: >"$test_dir/comments-fail"
run
expect_status 1
expect_no_comment
[[ ! -s $test_dir/watch-calls ]] || fail 'コメントを読めず見張りを入れた'
grep -qF 'コメントを読めない' "$test_dir/err"
echo 'PASS review-next: コメントを読めないときと範囲の行が不正なときは、見張りを入れる前に失敗する'

assert_no_rejected_calls
