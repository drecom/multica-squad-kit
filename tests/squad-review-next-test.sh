#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-test.sh で実行する。
# 共通の準備は tests/review-next-test-lib.sh。後半は squad-review-next-request-test.sh、Linux の引数の上限を超える大きな入力のケースは squad-review-next-arg-limit-test.sh に分けた。
# 実際のタスク・PR・エージェントには書き込まない。
source "$(dirname "$0")/review-next-test-lib.sh"

reset

# ---- マーク「重要」があるときは、有効な観点をすべて頼む。ファイルの一覧は読まない。
set_issue_labels label-imp
run
expect_request "$all" 'マーク「重要」があるため、有効な観点をすべて頼む'
[[ ! -s $test_dir/calls-gh.jsonl ]] || fail 'マークがあるのに GitHub を読んでいる'
# 別の種類（プロジェクト）の「重要」はマークにならない。
reset
set_issue_labels label-imp-project
run
expect_request code-reviewer '変えたファイル 1 件が対応に当たった（プロジェクト 0 件・既定 1 件）'
echo 'PASS review-next: マーク「重要」があれば有効な観点をすべて頼み、タスクのラベルでない「重要」はマークにしない'

# ---- 担当がメンバーのタスクでも、呼び出したリーダー（MULTICA_AGENT_ID）のスクワッドの名簿で依頼を書く。
reset
jq '. + {assignee_type: "member", assignee_id: "member-test"}' "$test_dir/issue.base.json" >"$test_dir/issue.json"
status=0
(cd "$test_dir" && MULTICA_AGENT_ID=orchestrator bash monitor/squad-review-next request test-issue trigger-1 "$sha") >"$test_dir/out" 2>"$test_dir/err" || status=$?
expect_request code-reviewer '変えたファイル 1 件が対応に当たった（プロジェクト 0 件・既定 1 件）'
# リーダーを決められなければ、担当のスクワッドへ戻り、担当もスクワッドでなければ、書かずに失敗する。
for caller in someone-else ''; do
	reset
	jq '. + {assignee_type: "member", assignee_id: "member-test"}' "$test_dir/issue.base.json" >"$test_dir/issue.json"
	status=0
	(cd "$test_dir" && MULTICA_AGENT_ID=$caller bash monitor/squad-review-next request test-issue trigger-1 "$sha") >"$test_dir/out" 2>"$test_dir/err" || status=$?
	expect_status 1
	expect_no_comment
	grep -q 'スクワッドの名簿を読めない' "$test_dir/err"
done
echo 'PASS review-next: 担当がメンバーのタスクでも、呼び出したリーダーのスクワッドの名簿で依頼を書く'

# ---- 既定の対応だけで選ぶ。対応が base のブランチ（release）の内容として 404 になる。
reset
set_files README.md docs/design.md src/run.sh
run
expect_request code-reviewer '変えたファイル 3 件が対応に当たった（プロジェクト 0 件・既定 3 件）'
[[ $(<"$test_dir/paths-refs") == release ]] || fail "対応を base のブランチで読んでいない: $(<"$test_dir/paths-refs")"
reset
set_files web/App.tsx
run
expect_request 'code-reviewer、ux-reviewer、qa' '変えたファイル 1 件が対応に当たった（プロジェクト 0 件・既定 1 件）'
reset
set_files src/auth/login.py db/migrations/0001_init.sql .github/workflows/ci.yml Dockerfile
run
expect_request 'code-reviewer、security-reviewer、performance-reviewer' '変えたファイル 4 件が対応に当たった（プロジェクト 0 件・既定 4 件）'
reset
set_files lib/user-permissions.rb tests/foo-test.sh app/models/user.spec.ts
run
expect_request 'code-reviewer、security-reviewer' '変えたファイル 3 件が対応に当たった（プロジェクト 0 件・既定 3 件）'
echo 'PASS review-next: 既定の対応で、文書・画面・認証・配布・データベース・テスト・ソースの場所から観点を選び、有効な観点の順に並べる'

# ---- プロジェクトの上書きと追加。
reset
set_files docs/design.md src/run.sh
set_paths <<'EOF'
# 文書は QA も見る
docs/ code-reviewer,qa
EOF
run
expect_request 'code-reviewer、qa' '変えたファイル 2 件が対応に当たった（プロジェクト 1 件・既定 1 件）'
reset
set_files docs/design.md
set_paths <<'EOF'
docs/ qa

*.md security-reviewer  # 同じ側の複数の行は合わせる
EOF
run
expect_request 'security-reviewer、qa' '変えたファイル 1 件が対応に当たった（プロジェクト 1 件・既定 0 件）'
reset
set_files api/service.proto src/run.sh
set_paths <<'EOF'
*.proto security-reviewer
EOF
run
expect_request 'code-reviewer、security-reviewer' '変えたファイル 2 件が対応に当たった（プロジェクト 1 件・既定 1 件）'
[[ $(<"$test_dir/paths-refs") == release ]]
echo 'PASS review-next: プロジェクトの対応は既定を上書きし、既定にない場所を足し、同じ側の行は合わせる'

# ---- 当たらないファイルが 1 つでもあれば、有効な観点をすべて頼む。
reset
set_files src/run.sh data/blob.bin assets/logo.dat
run
expect_request "$all" '対応に当たらないファイルが 2 件あるため、有効な観点をすべて頼む'
# 型に / を含まなければどの深さにも当たり、含めば根から当たる。
reset
set_files a/b/c/run.sh
run
expect_request code-reviewer '変えたファイル 1 件が対応に当たった（プロジェクト 0 件・既定 1 件）'
reset
set_files vendor/docs/guide.txt
set_paths <<'EOF'
docs/ qa
EOF
run
expect_request "$all" '対応に当たらないファイルが 1 件あるため、有効な観点をすべて頼む'
echo 'PASS review-next: 対応に当たらないファイルがあれば有効な観点をすべて頼み、/ を含む型は根から当てる'

# ---- 読めない対応は、有効な観点をすべて頼む。
for bad in 'docs/ code-reviewer extra' 'docs/' '*.md reviewer' 'bad|name qa' '/abs/path qa' '*.md code-reviewer,,qa'; do
	reset
	set_files src/run.sh
	printf '%s\n' "$bad" | set_paths
	run
	expect_status 0
	grep -qF "観点: ${all}（$(all_reason '')" "$test_dir/out" || fail "読めない対応で全部を頼んでいない: ${bad}: $(<"$test_dir/out")"
	grep -qE '1 行目' "$test_dir/out" || fail "読めない理由に行がない: ${bad}: $(<"$test_dir/out")"
	[[ $(<"$test_dir/watch-calls") == "watch test-issue trigger-1 ${all//、/ }" ]]
done
# 1 行でも誤りがあれば、ほかの行で選ばない。
reset
set_files docs/design.md
printf 'docs/ qa\n*.md nobody\n' | set_paths
run
grep -qF "観点: ${all}（$(all_reason 'プロジェクトの対応の2 行目に知らない役の名前がある')）" "$test_dir/out" || fail "誤りの行を書いていない: $(<"$test_dir/out")"
# 404 以外の失敗も、読めないとする。
reset
echo error >"$test_dir/paths-mode"
run
expect_request "$all" "$(all_reason 'プロジェクトの対応を読み取れない')"
# base のブランチが読めなければ、読めないとする。
reset
touch "$test_dir/pr-fail"
run
expect_request "$all" "$(all_reason 'PR の base のブランチを読めない')"
echo 'PASS review-next: 形の誤りが 1 行でもあるか、base の対応を 404 以外で読めなければ、有効な観点をすべて頼む。ないときは既定だけで選ぶ'

assert_no_rejected_calls
