#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-arg-limit-test.sh で実行する。
# 共通の準備は tests/review-next-test-lib.sh。
# 実際のタスク・PR・エージェントには書き込まない。
source "$(dirname "$0")/review-next-test-lib.sh"
reset

# ---- Linux の引数の上限（131,072 バイト）を超える値でも、小さな値と同じ観点を選ぶ。
# 準備の jq は上限を超える引数を拒む包みで、拒んだ呼び出しがあれば終わるときにテストが失敗する。
# 大きな値は引数に載せず、標準入力で jq に渡す。
for f in agents squads labels; do cp "$test_dir/$f.json" "$test_dir/$f.orig.json"; done
# ファイル $1 の jq の式 $2 に、140,000 バイトの文字列 $big を渡して書き換える。
inflate() {
	head -c 140000 /dev/zero | tr '\0' a \
		| jq -Rs --slurpfile base "$1" ". as \$big | \$base[0] | $2" >"$test_dir/inflated.json"
	mv "$test_dir/inflated.json" "$1"
	(($(wc -c <"$1") >= 140000))
}
restore_fixtures() {
	for f in agents squads labels; do cp "$test_dir/$f.orig.json" "$test_dir/$f.json"; done
}
# ワークスペースのラベルの一覧を、先頭の 3 件に 3,000 件を足して 131,072 バイトを超える大きさにする。
many_labels() {
	jq '. + [range(3000) as $n | .[0] + {id: "extra-\($n)", name: "追加のラベル-\($n)-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]' "$test_dir/labels.json" >"$test_dir/inflated.json"
	mv "$test_dir/inflated.json" "$test_dir/labels.json"
	(($(wc -c <"$test_dir/labels.json") >= 140000))
}
# 対応ファイルを、標準入力の内容に 140,000 バイトのコメントの行を足して置く。
set_big_paths() {
	{ cat; printf '# '; head -c 140000 /dev/zero | tr '\0' a; echo; } | base64 | tr -d '\n' \
		| jq -Rs --slurpfile base <(fixture gh-file) '$base[0] + {content: ., encoding: "base64", type: "file"}' >"$test_dir/paths-file.json"
	echo present >"$test_dir/paths-mode"
	(($(wc -c <"$test_dir/paths-file.json") >= 140000))
}

# 変えたファイルの一覧に、140,000 バイトの patch を持つファイルがあっても、同じ観点を選び、すべてを頼まない。
reset
set_files web/App.tsx src/run.sh
run
expect_request 'code-reviewer、ux-reviewer、qa' '変えたファイル 2 件が対応に当たった（プロジェクト 0 件・既定 2 件）'
reset
set_files web/App.tsx src/run.sh
inflate "$test_dir/files.json" '.[0].patch = $big'
run
expect_request 'code-reviewer、ux-reviewer、qa' '変えたファイル 2 件が対応に当たった（プロジェクト 0 件・既定 2 件）'
echo 'PASS review-next: 140,000 バイトの patch を持つファイルの一覧でも、小さな一覧と同じ観点を選び、拒まれた jq の呼び出しがない'

# 大きな .agents/review-paths でも、同じ観点を選ぶ。
reset
set_files docs/design.md src/run.sh
set_paths <<'PATHS'
docs/ qa
PATHS
run
expect_request 'code-reviewer、qa' '変えたファイル 2 件が対応に当たった（プロジェクト 1 件・既定 1 件）'
reset
set_files docs/design.md src/run.sh
set_big_paths <<'PATHS'
docs/ qa
PATHS
run
expect_request 'code-reviewer、qa' '変えたファイル 2 件が対応に当たった（プロジェクト 1 件・既定 1 件）'
echo 'PASS review-next: 140,000 バイトを超える .agents/review-paths でも、小さな対応と同じ観点を選び、拒まれた jq の呼び出しがない'

# ラベルの一覧が大きくても、マークの有無の判断が同じ。一覧は約束の欄だけに絞られるので、ラベルを 3,000 件に増やして 131,072 バイトを超える。
for marked in label-imp label-dev; do
	reset
	set_issue_labels "$marked"
	run
	small_out=$(<"$test_dir/out")
	reset
	set_issue_labels "$marked"
	many_labels
	run
	[[ $(<"$test_dir/out") == "$small_out" ]] || fail "大きなラベルの一覧で観点が変わった: ${marked}: $(<"$test_dir/out")"
	restore_fixtures
done
reset
set_issue_labels label-imp
many_labels
run
expect_request "$all" 'マーク「重要」があるため、有効な観点をすべて頼む'
restore_fixtures
reset
many_labels
run
expect_request code-reviewer '変えたファイル 1 件が対応に当たった（プロジェクト 0 件・既定 1 件）'
restore_fixtures
echo 'PASS review-next: 140,000 バイトを超えるラベルの一覧でも、マークの有無の判断が小さな一覧と同じで、拒まれた jq の呼び出しがない'

# 役とスクワッドの指示が大きくても、名簿を読めて、同じ観点を頼む。読み取りは約束の欄だけに絞るため、指示は名簿の読み取りに届かない。
# この場面は修正の前後で結果が変わらない（絞りが指示を落とす性質の回帰を確認する）。
reset
inflate "$test_dir/agents.json" '[.[] | .instructions = $big]'
inflate "$test_dir/squads.json" '[.[] | .instructions = $big]'
run
expect_request code-reviewer '変えたファイル 1 件が対応に当たった（プロジェクト 0 件・既定 1 件）'
restore_fixtures
echo 'PASS review-next: 役とスクワッドの指示が 140,000 バイトを超えても、名簿を読めて、拒まれた jq の呼び出しがない'
assert_no_rejected_calls
