#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-merge-note-depth-test.sh で実行する。
# この部分は、本文を読めないとき・読む深さ・残した指摘・前からある不具合を確認する。
# squad-review-next decide のマージの依頼に書く注意・読む深さ・残した指摘・前からある不具合を確認する。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
source "$(dirname "$0")/review-next-decide-merge-note-lib.sh"

# 整えたあとも本文が読めなくなったときは、注意の行を読めない旨に替えて 1 回だけ確認し直す。
note_case $'## 注意\n\n[>](mention://agent/agent-9) 確認\n評価を流し直す' "${N}: 読めない（写すと読めない本文になる）"
echo 'PASS review-next-decide: 写すと本文が読めなくなるときは、注意の行を読めない旨に替えて書く'

# PR の本文を読めないときも、依頼は書く。
reset
set_roster orchestrator code-reviewer qa
ok_round
touch "$test_dir/body-fail"
merge_note="${N}: 読めない（PR の本文を読めなかった）"
merge_depth=$(depth_of "$merge_note")
run round-1
expect_merge_posted "$(merge_body round-1 "$sha" "$conf_line" "${plain_lines[@]}")"
echo 'PASS review-next-decide: PR の本文を読めないときも、読めない旨の行を添えてマージの依頼を書く'

# PR の本文は、確認がすべて通ったあとに読む。止まるときは読まない。
reset
final_ok
printf 'コンフリクト: CONFLICTING head: %s\n' "$sha" >"$test_dir/conf-out"
run final-1
expect_leader 'コンフリクト: CONFLICTING'
expect_no_calls body-calls
echo 'PASS review-next-decide: 確認で止まるときは、PR の本文を読まない'

# ---- 読む深さ・直さずに残した指摘・前からある不具合。組の結果の要約から読み、役の結果の前に置く。
# 組を 1 つ作る。code-reviewer と qa に頼み、最上位の役はいない。結果は、呼んだあとに result で足す。
two_roles_round() {
	reset
	set_roster orchestrator code-reviewer qa
	base_round
}
depth_line() { # 深さ 重要か 注意 指摘の件数 前からある不具合の件数
	printf '読む深さ: %s（%s。%s、残した指摘 %s 件、前からある不具合 %s 件）' "$1" "$2" "$3" "$4" "$5"
}
# 3-1: 深さは 3 つとも出る。重要のマークが先に当たり、次に注意・指摘・前からある不具合のどれかがあるとき、なければコメントだけ。
two_roles_round
all_ok round-1 "$sha" code-reviewer qa
merge_depth=$(depth_line このコメントだけ 重要でない 注意なし 0 0)
run round-1
expect_merge_posted "$(merge_body round-1 "$sha" "$conf_line" "${plain_lines[@]}")"
two_roles_round
result round-1 code-reviewer ✅ "$sha" なし
result round-1 qa ✅ "$sha" なし '前からある不具合 2 件'
merge_depth=$(depth_line 'このコメントと PR の注意' 重要でない 注意なし 0 2)
merge_pre='前からある不具合: 2 件（demo-qa-test 2 件）'
run round-1
expect_merge_posted "$(merge_body round-1 "$sha" "$conf_line" '✅ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 前からある不具合 2 件')"
two_roles_round
result round-1 code-reviewer ⚠️ "$sha" なし 結果 $'指摘の一覧: 1 件\n- 1. 推奨: a.js:3。影響: 値がずれる'
result round-1 qa ✅ "$sha" なし
merge_depth=$(depth_line 'このコメントと PR の注意' 重要でない 注意なし 1 0)
merge_findings=$'直さずに残した指摘: 1 件\n- demo-code-reviewer-test 1. 推奨: a.js:3。影響: 値がずれる'
run round-1
expect_merge_posted "$(merge_body round-1 "$sha" "$conf_line" '⚠️ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')"
two_roles_round
set_issue_labels label-imp
all_ok round-1 "$sha" code-reviewer qa
merge_depth=$(depth_line 'PR の概要と設計文書まで' 重要のタスク 注意なし 0 0)
run round-1
expect_merge_posted "$(merge_body round-1 "$sha" "$conf_line" "${plain_lines[@]}")"
# 重要のマークは、注意や指摘や前からある不具合がなくても先に当たる。注意があれば、その状態も深さの行に出る。
two_roles_round
set_issue_labels label-imp
set_pr_body $'## 注意\n\n評価を流し直す'
all_ok round-1 "$sha" code-reviewer qa
merge_depth=$(depth_line 'PR の概要と設計文書まで' 重要のタスク 注意あり 0 0)
merge_note='マージの前に人間がすること: 評価を流し直す'
run round-1
expect_merge_posted "$(merge_body round-1 "$sha" "$conf_line" "${plain_lines[@]}")"
echo 'PASS review-next-decide: 読む深さは、重要・注意・指摘・前からある不具合で、PR の概要まで・注意まで・コメントだけの 3 つが決まった順で出て、4 つの行が固定の順で並ぶ'

# 3-2: ⚠️ の要約の `指摘の一覧:` を 1 件 1 行で書く。一覧のない ⚠️ は 1 件。件数が項目より多ければ、残りを示す。11 件以上は 10 行で切る。
two_roles_round
result round-1 code-reviewer ⚠️ "$sha" なし 結果 $'指摘の一覧: 2 件\n- 1. 推奨: a.js:3。影響: 値がずれる\n- 2. 軽微: b.js。影響: 文言が古い\n成果物: PR のコメント'
result round-1 qa ⚠️ "$sha" なし
merge_depth=$(depth_line 'このコメントと PR の注意' 重要でない 注意なし 3 0)
merge_findings=$'直さずに残した指摘: 3 件\n- demo-code-reviewer-test 1. 推奨: a.js:3。影響: 値がずれる\n- demo-code-reviewer-test 2. 軽微: b.js。影響: 文言が古い\n- demo-qa-test: 指摘の行を読めない。結果を読む'
run round-1
expect_merge_posted "$(merge_body round-1 "$sha" "$conf_line" '⚠️ demo-code-reviewer-test: 結果' '⚠️ demo-qa-test: 結果')"
# 一覧の件数が項目より多い。2 回ある、件数が 0・数字でないときも、読めない旨の 1 件にする。
two_roles_round
result round-1 code-reviewer ⚠️ "$sha" なし 結果 $'指摘の一覧: 3 件\n- 1. 推奨: a.js:3。影響: 値がずれる'
result round-1 qa ⚠️ "$sha" なし 結果 $'指摘の一覧: 2 件\n- 1. 推奨: x\n指摘の一覧: 1 件\n- 1. 推奨: y'
merge_depth=$(depth_line 'このコメントと PR の注意' 重要でない 注意なし 4 0)
merge_findings=$'直さずに残した指摘: 4 件\n- demo-code-reviewer-test 1. 推奨: a.js:3。影響: 値がずれる\n- demo-code-reviewer-test: ほか 2 件は結果を読む\n- demo-qa-test: 指摘の行を読めない。結果を読む'
run round-1
expect_merge_posted "$(merge_body round-1 "$sha" "$conf_line" '⚠️ demo-code-reviewer-test: 結果' '⚠️ demo-qa-test: 結果')"
for head in '指摘の一覧: 0 件' '指摘の一覧: 多い 件' '指摘の一覧:'; do
	two_roles_round
	result round-1 code-reviewer ✅ "$sha" なし
	result round-1 qa ⚠️ "$sha" なし 結果 "$head"$'\n- 1. 推奨: x'
	merge_depth=$(depth_line 'このコメントと PR の注意' 重要でない 注意なし 1 0)
	merge_findings=$'直さずに残した指摘: 1 件\n- demo-qa-test: 指摘の行を読めない。結果を読む'
	run round-1
	expect_merge_posted "$(merge_body round-1 "$sha" "$conf_line" '✅ demo-code-reviewer-test: 結果' '⚠️ demo-qa-test: 結果')"
done
# 11 件は、10 行で切り、残りの件数を 1 行にする。件数の行は 11 件のまま。
eleven_items=$(printf -- '- %s. 軽微: f.js。影響: x\n' 1 2 3 4 5 6 7 8 9 10 11)
two_roles_round
result round-1 code-reviewer ⚠️ "$sha" なし 結果 $'指摘の一覧: 11 件\n'"$eleven_items"
result round-1 qa ✅ "$sha" なし
merge_depth=$(depth_line 'このコメントと PR の注意' 重要でない 注意なし 11 0)
merge_findings="直さずに残した指摘: 11 件
$(printf -- '- demo-code-reviewer-test %s. 軽微: f.js。影響: x\n' 1 2 3 4 5 6 7 8 9 10)
- ほか 1 件は各役の結果を読む"
run round-1
expect_merge_posted "$(merge_body round-1 "$sha" "$conf_line" '⚠️ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')"
# 1 つの項目が 200 字を超えたら、200 字で切って … を添える。字下げや引用の記号は外す。
a250=$(printf 'あ%.0s' $(seq 250))
two_roles_round
result round-1 code-reviewer ⚠️ "$sha" なし 結果 $'指摘の一覧: 2 件\n- '"$a250"$'\n-   > 1. 重大: c.js。影響: 落ちる'
result round-1 qa ✅ "$sha" なし
merge_depth=$(depth_line 'このコメントと PR の注意' 重要でない 注意なし 2 0)
merge_findings="直さずに残した指摘: 2 件
- demo-code-reviewer-test ${a250:0:200}…
- demo-code-reviewer-test 1. 重大: c.js。影響: 落ちる"
run round-1
expect_merge_posted "$(merge_body round-1 "$sha" "$conf_line" '⚠️ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')"
echo 'PASS review-next-decide: ⚠️ の要約の指摘を 1 件 1 行で書き、一覧のない ⚠️ は 1 件、件数が多ければ残りを示し、11 件以上は 10 行で切り、長い項目は 200 字で切る'

# 3-3: PR とタスクの分け方。PR のコメントに指摘の全文があり、タスクの要約には一覧と件数だけがある。2 役の指摘と前からある不具合の合計をマージの依頼に出し、PR のコメントは読まない。
two_roles_round
result round-1 code-reviewer ⚠️ "$sha" なし '推奨 1 件、前からある不具合 2 件。マージは止めない' $'指摘の一覧: 1 件\n- 1. 推奨: a.js:3。影響: 値がずれる\n成果物: PR のコメント '"$pr_url"$'#issuecomment-1\n前からある不具合: 2 件'
result round-1 qa ⚠️ "$sha" なし '推奨 1 件、前からある不具合 1 件。マージは止めない' $'指摘の一覧: 1 件\n- 1. 推奨: 画面 b。影響: 文言が古い'
merge_depth=$(depth_line 'このコメントと PR の注意' 重要でない 注意なし 2 3)
merge_findings=$'直さずに残した指摘: 2 件\n- demo-code-reviewer-test 1. 推奨: a.js:3。影響: 値がずれる\n- demo-qa-test 1. 推奨: 画面 b。影響: 文言が古い'
merge_pre='前からある不具合: 3 件（demo-code-reviewer-test 2 件、demo-qa-test 1 件）'
run round-1
expect_merge_posted "$(merge_body round-1 "$sha" "$conf_line" '⚠️ demo-code-reviewer-test: 推奨 1 件、前からある不具合 2 件。マージは止めない' '⚠️ demo-qa-test: 推奨 1 件、前からある不具合 1 件。マージは止めない')"
if grep -q 'comments' "$test_dir/calls-gh.jsonl"; then fail "gh で PR のコメントを読んでいる: $(<"$test_dir/calls-gh.jsonl")"; fi
echo 'PASS review-next-decide: PR とタスクの分け方でも、タスクの要約から 2 役の指摘と前からある不具合の合計を書き、PR のコメントは読まない'

# 3-4: 組の外のコメントは数えない。頼まれていない役、前の回の返事、違うコミットの確認は、一覧も件数も出ない。
two_roles_round
add stray-ux ux-reviewer $'/note\n返事の回: round-1\n確認したコミット: '"$sha"$'\n⚠️ demo-ux-reviewer-test: 前からある不具合 5 件\n設計への指摘: なし\n指摘の一覧: 2 件\n- 1. 推奨: 無関係 A\n- 2. 推奨: 無関係 B'
result older-1 qa ⚠️ "$sha" なし '前からある不具合 4 件' $'指摘の一覧: 1 件\n- 1. 推奨: 前の回'
result round-1 qa ⚠️ "$old" なし '前からある不具合 3 件' $'指摘の一覧: 1 件\n- 1. 推奨: 違うコミット'
result round-1 code-reviewer ✅ "$sha" なし
result round-1 qa ✅ "$sha" なし
merge_depth=$(depth_line このコメントだけ 重要でない 注意なし 0 0)
run round-1
expect_merge_posted "$(merge_body round-1 "$sha" "$conf_line" "${plain_lines[@]}")"
echo 'PASS review-next-decide: 頼まれていない役・前の回・違うコミットの一覧と件数は、読む深さにも指摘にも前からある不具合にも出ない'

# 4-2: 前からある不具合は、組の結果と最終レビューの結果から足す。役ごとの内訳を括弧で出し、件数のない結果は 0 件にする。
reset
set_merge_roster
base_round
result round-1 code-reviewer ✅ "$sha" なし '前からある不具合 2 件'
result round-1 qa ✅ "$sha" なし
set_principal_pick claude-principal
final_round final-1 "$sha" round-1
result final-1 claude-principal ✅ "$sha" なし '前からある不具合 1 件'
merge_depth=$(depth_line 'このコメントと PR の注意' 重要でない 注意なし 0 3)
merge_pre='前からある不具合: 3 件（demo-claude-principal-test 1 件、demo-code-reviewer-test 2 件）'
run final-1
expect_merge_posted "$(merge_body final-1 "$sha" "$conf_line" '✅ demo-claude-principal-test: 前からある不具合 1 件' '✅ demo-code-reviewer-test: 前からある不具合 2 件' '✅ demo-qa-test: 結果')" final-1
echo 'PASS review-next-decide: 前からある不具合は、組の結果と最終レビューの結果から足し、役ごとの内訳を出し、件数のない結果は 0 件にする'

# 6-2: 写した指摘にメンションのリンクがあっても、エージェントへのメンションは生まれない。呼ぶ人間のリンクだけが残る。
two_roles_round
result round-1 code-reviewer ⚠️ "$sha" なし 結果 $'指摘の一覧: 2 件\n- 1. 推奨: [@Agent](mention://agent/agent-9) に聞く。影響: x\n- 2. 軽微: mention://agent/agent-9 は残る'
result round-1 qa ✅ "$sha" なし
merge_depth=$(depth_line 'このコメントと PR の注意' 重要でない 注意なし 2 0)
merge_findings=$'直さずに残した指摘: 2 件\n- demo-code-reviewer-test 1. 推奨: @Agent に聞く。影響: x\n- demo-code-reviewer-test 2. 軽微: mention: //agent/agent-9 は残る'
run round-1
expect_merge_posted "$(merge_body round-1 "$sha" "$conf_line" '⚠️ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')"
[[ $(grep -o 'mention://' <<<"$(posted_body)" | wc -l | tr -d ' ') == 1 ]] || fail "mention:// が 1 つでない: $(posted_body)"
[[ $(posted_body) != *'mention://agent/'* ]] || fail "エージェントへのメンションがある: $(posted_body)"
echo 'PASS review-next-decide: 写した指摘のメンションのリンクは文字だけになり、mention:// が呼ぶ人間の 1 つだけ残る'

# 写す文の整え方の 4: 指摘の項目のコードの囲みの行と囲みの中、`<` で始まる項目は捨て、注意の行と同じ 1 行を 1 回だけ足す。件数は捨てた項目も数える。
two_roles_round
result round-1 code-reviewer ⚠️ "$sha" なし 結果 $'指摘の一覧: 5 件\n- 1. 推奨: a.js:3。影響: 値がずれる\n- ```js\n- const x = 1\n- ```\n- <b>html</b>'
result round-1 qa ✅ "$sha" なし
merge_depth=$(depth_line 'このコメントと PR の注意' 重要でない 注意なし 5 0)
merge_findings=$'直さずに残した指摘: 5 件\n- demo-code-reviewer-test 1. 推奨: a.js:3。影響: 値がずれる\n- （コードの囲みや HTML は PR の本文の注意を読む）'
run round-1
expect_merge_posted "$(merge_body round-1 "$sha" "$conf_line" '⚠️ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')"
echo 'PASS review-next-decide: 写した指摘のコードの囲みと HTML の項目は捨て、1 行の注意を 1 回だけ足し、件数は捨てた項目も数える'

# 指摘の項目の囲みも、開きと同じ文字で、開きの長さ以上のときだけ閉じる。4 文字の囲みの中の 3 文字は閉じず、閉じのあとの項目は残る。
two_roles_round
result round-1 code-reviewer ⚠️ "$sha" なし 結果 $'指摘の一覧: 5 件\n- ````\n- ```\n- 例です\n- ````\n- 1. 推奨: a.js:3。影響: 値がずれる'
result round-1 qa ✅ "$sha" なし
merge_depth=$(depth_line 'このコメントと PR の注意' 重要でない 注意なし 5 0)
merge_findings=$'直さずに残した指摘: 5 件\n- demo-code-reviewer-test 1. 推奨: a.js:3。影響: 値がずれる\n- （コードの囲みや HTML は PR の本文の注意を読む）'
run round-1
expect_merge_posted "$(merge_body round-1 "$sha" "$conf_line" '⚠️ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')"
echo 'PASS review-next-decide: 写した指摘の囲みは、開きと同じ文字で開きの長さ以上のときだけ閉じる'
