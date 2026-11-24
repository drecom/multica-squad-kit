#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-merge-test.sh で実行する。
# squad-review-next decide のマージの依頼（確認の流れ・規則の登録・コメント・止まる値）を確認する。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"

unlinked() { printf '紐付け: 紐付いていない pr: %s\n' "$pr_url" >"$test_dir/link-out"; }
conf_line="コンフリクト: MERGEABLE head: $sha"
final_ok() { # 最終レビューまで済んだ状態にする。回は final-1
	set_merge_roster
	ok_round
	final_round final-1 "$sha" round-1
	result final-1 claude-principal ✅ "$sha" なし
}
lines_all=('✅ demo-claude-principal-test: 結果' '✅ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')

# ---- 紐付いているとき。確認は head・コンフリクトだけで、CI は読まず、コンフリクトの規則だけを入れ直す。
reset
final_ok
run final-1
expect_merge_posted "$(merge_body final-1 "$sha" "$conf_line" "${lines_all[@]}")" final-1
expect_calls pr-watch-calls $'link-check test-issue final-1\nconflicts-check test-issue\nconflicts test-issue --leader orchestrator'
expect_calls head-calls 'pr view 7 --repo demo/project --json headRefOid'
echo 'PASS review-next-decide: 紐付いているマージの依頼は、head とコンフリクトを確認し、CI を読まず、コンフリクトの規則を入れてから書く'

# ---- 紐付いていないとき。その場の CI を読み、unlinked を入れ、紐付けの案内と見張りの行を添える。
reset
final_ok
unlinked
printf 'CI %s: 成功\n' "${sha:0:7}" >"$test_dir/cinow-out"
run final-1
expect_merge_posted "$(merge_body final-1 "$sha" "$conf_line" "CI ${sha:0:7}: 成功" "${lines_all[@]}" \
	"紐付いていないので、マージのあとにタスクを \`done\` にしてほしい（または先に紐付けてほしい）。PR: \`${pr_url}\`" \
	'見張り: 1 時間おき、2026-11-17 まで')" final-1
expect_calls pr-watch-calls $'link-check test-issue final-1\nconflicts-check test-issue\nci-held test-issue final-1\nci-now test-issue orchestrator final-1\nconflicts test-issue --leader orchestrator\nunlinked test-issue final-1 --leader orchestrator'
echo 'PASS review-next-decide: 紐付いていないマージの依頼は、その場の CI を読み、unlinked を入れて、紐付けの案内と見張りの行を添える'

# 紐付けの失敗の段落と連携の案内は、PR を作った役の引き継ぎから写す。
reset
final_ok
unlinked
n=0
comments=$(jq 'del(.[] | select(.id == "pr-made"))' "$test_dir/comments.json")
echo "$comments" >"$test_dir/comments.json"
add pr-made claude-implementer "PR を作りました ${pr_url}"$'\n\n紐付けの失敗: PR をタスクに紐付けられなかった。\n404 で待ち切れなかったため、連携を確認してほしい。' ""
run final-1
expect_status 0
body=$(posted_body)
[[ $body == *$'\n紐付けの失敗: PR をタスクに紐付けられなかった。'* ]] || fail "紐付けの失敗の段落がない: $body"
echo 'PASS review-next-decide: 紐付けの失敗の段落を、PR を作った役の引き継ぎから写す'

# ---- unlinked の出力。
reset
final_ok
unlinked
printf '紐付け: 紐付いていない pr: 不明\n' >"$test_dir/unlinked-out"
run final-1
expect_leader '紐付け: 紐付いていない'
reset
final_ok
unlinked
echo 1 >"$test_dir/unlinked-status"
run final-1
expect_status 0
body=$(posted_body)
[[ $body == *'登録できませんでした。ホストでセットアップを流し直してください。'* ]] || fail "登録できなかった旨がない: $body"
[[ $body != *'見張り:'* ]] || fail "見張りの行を書いてはいけない: $body"
reset
final_ok
unlinked
printf '{"id": "rule-1"}\n' >"$test_dir/unlinked-out"
run final-1
expect_status 0
[[ $(posted_body) == *'登録できませんでした。ホストでセットアップを流し直してください。'* ]] || fail "見張りの行がないのに、登録できなかった旨がない: $(posted_body)"
# 紐付いているときは、unlinked を流さない。
reset
final_ok
run final-1
expect_status 0
expect_call_lacks pr-watch-calls unlinked
expect_call_lacks pr-watch-calls ci-now
expect_call_lacks pr-watch-calls ci-held
echo 'PASS review-next-decide: unlinked は、紐付け: の行なら止まり、0 以外や行なしなら見張りなしで進み、紐付いていれば流さない'

# ---- 規則の登録とコンフリクトと CI の止まる値。止まるときは、書かず、状態も変えない。
reset
final_ok
echo 1 >"$test_dir/conflicts-status"
run final-1
expect_leader 'コンフリクトの規則を入れ直せない'
reset
final_ok
printf 'コンフリクト: CONFLICTING head: %s\n' "$sha" >"$test_dir/conf-out"
run final-1
expect_leader 'コンフリクト: CONFLICTING'
expect_call_lacks pr-watch-calls 'conflicts test-issue'
reset
final_ok
unlinked
printf 'CI %s: 失敗あり（lint）\n' "${sha:0:7}" >"$test_dir/cinow-out"
run final-1
expect_leader "CI ${sha:0:7}: 失敗あり（lint）"
expect_call_lacks pr-watch-calls 'conflicts test-issue'
reset
final_ok
unlinked
printf 'CI %s: 失敗あり（テスト）\n' "${sha:0:7}" >"$test_dir/held-out"
run final-1
expect_leader '保留した CI の失敗がある'
reset
final_ok
unlinked
echo 1 >"$test_dir/cinow-status"
run final-1
expect_leader 'CI のその場の確認が 0 以外で終わった'
# コンフリクトの行が出なければ、未確認として書く。
reset
final_ok
: >"$test_dir/conf-out"
run final-1
expect_status 0
[[ $(posted_body) == *$'\nコンフリクト: 未確認 head: '"$sha"$' 理由: 判定の行が出なかった\n'* ]] || fail "未確認の行がない: $(posted_body)"
echo 'PASS review-next-decide: マージの依頼の確認で止まる値は、書かず、状態も変えずにリーダーに任せる'

# ---- コンフリクトで止まったあとの再開。止まった回は何も書かないので、解消のあとに同じ回で流し直せば、conflicts と、紐付いていないときの unlinked が登録される。
# 同じ回の流し直しで、最上位の役の有無と紐付けの有無の 4 つの組のどれでも同じ登録が揃う。手で流す経路の文は agent-templates-test.sh が確認する。
resume_after_conflict() { # 構成（principal|plain） 紐付け（linked|unlinked）
	local kind=$1 link=$2 round
	reset
	if [[ $kind == principal ]]; then
		final_ok
		round=final-1
	else
		set_roster orchestrator code-reviewer qa
		ok_round
		round=round-1
	fi
	[[ $link == linked ]] || unlinked
	[[ $link == linked ]] || printf 'CI %s: 成功\n' "${sha:0:7}" >"$test_dir/cinow-out"
	printf 'コンフリクト: CONFLICTING head: %s\n' "$sha" >"$test_dir/conf-out"
	run "$round"
	expect_leader 'コンフリクト: CONFLICTING'
	expect_call_lacks pr-watch-calls 'conflicts test-issue'
	expect_call_lacks pr-watch-calls 'unlinked test-issue'
	printf 'コンフリクト: MERGEABLE head: %s\n' "$sha" >"$test_dir/conf-out"
	run "$round"
	expect_status 0
	[[ $(<"$test_dir/out") == $'次の依頼: マージの依頼'* ]] || fail "再開しても依頼が書かれない: $(<"$test_dir/out")"
	expect_call_has pr-watch-calls 'conflicts test-issue --leader orchestrator'
	if [[ $link == linked ]]; then
		expect_call_lacks pr-watch-calls 'unlinked test-issue'
	else
		grep -q -- "^unlinked test-issue ${round} --leader orchestrator" "$test_dir/pr-watch-calls" || fail "unlinked が登録されない: $(<"$test_dir/pr-watch-calls")"
	fi
	[[ $(grep -c -- '^conflicts test-issue' "$test_dir/pr-watch-calls") == 1 ]] || fail "conflicts の登録が 1 回でない: $(<"$test_dir/pr-watch-calls")"
}
for kind in principal plain; do
	for link in linked unlinked; do
		resume_after_conflict "$kind" "$link"
	done
done
echo 'PASS review-next-decide: コンフリクトで止まったあと、解消してから同じ回を流し直すと、最上位の役の有無と紐付けの有無によらず conflicts（と、紐付いていなければ unlinked）を登録する'

# ---- head の照合。
reset
final_ok
printf '{"headRefOid": "%s"}\n' "$old" >"$test_dir/head.json"
run final-1
expect_leader "PR の今の head（${old}）が最終レビューの確認したコミット（${sha}）と違う"
expect_call_lacks pr-watch-calls 'conflicts test-issue'
# 確認したコミットが短い SHA でも、head の先頭と合えば一致とする。
reset
final_ok
add res-short claude-principal $'/note\n返事の回: final-1\n確認したコミット: '"${sha:0:7}"$'\n✅ demo-claude-principal-test: 結果\n設計への指摘: なし' final-1
run final-1
expect_status 0
reset
final_ok
echo 1 >"$test_dir/head-fail"
run final-1
expect_failure 'PR の今の head を読めない'
reset
final_ok
printf '{"headRefOid": "short"}\n' >"$test_dir/head.json"
run final-1
expect_failure 'PR の今の head を読めない'
# 最上位の役が名簿になければ照合せず、マージの依頼の head は PR の今の head にする。
reset
set_roster orchestrator code-reviewer qa
ok_round
printf '{"headRefOid": "%s"}\n' "$old" >"$test_dir/head.json"
run round-1
expect_merge_posted "$(merge_body round-1 "$old" "コンフリクト: MERGEABLE head: $sha" '✅ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')"
echo 'PASS review-next-decide: 最上位の役があれば、PR の今の head を最終レビューの確認したコミットと照合し、一致しなければ書かない'

# ---- QA の確認。QA が選ばれる変更なのに、組に QA の結果がなければ、確認を流さずにリーダーに任せる。
reset
set_merge_roster
base_round_without_qa() {
	add pr-made orchestrator "PR を作りました ${pr_url}" ""
	review_round round-1 "$sha" code-reviewer
	all_ok round-1 "$sha" code-reviewer
	set_principal_pick claude-principal
}
base_round_without_qa
final_round final-1 "$sha" round-1
result final-1 claude-principal ✅ "$sha" なし
run final-1
expect_leader 'QA が選ばれる変更なのに、組に QA の結果がない'
expect_no_calls pr-watch-calls
expect_no_calls head-calls
# 画面に触れない変更なら、QA が選ばれないので、結果がなくても進む。
set_changed_files README.md
run final-1
expect_merge_posted "$(merge_body final-1 "$sha" "$conf_line" '✅ demo-claude-principal-test: 結果' '✅ demo-code-reviewer-test: 結果')" final-1
# 画面に触れる変更なら、QA が選ばれるので、結果がなければ止まる。
reset
set_merge_roster
base_round_without_qa
final_round final-1 "$sha" round-1
result final-1 claude-principal ✅ "$sha" なし
set_changed_files web/App.tsx
run final-1
expect_leader 'QA が選ばれる変更なのに、組に QA の結果がない'
# マーク「重要」があれば、有効な観点がすべて選ばれる。
reset
set_merge_roster
base_round_without_qa
final_round final-1 "$sha" round-1
result final-1 claude-principal ✅ "$sha" なし
set_changed_files README.md
set_issue_labels label-imp
run final-1
expect_leader 'QA が選ばれる変更なのに、組に QA の結果がない'
# QA の役が名簿になければ、確認しない。
reset
set_roster orchestrator code-reviewer claude-principal
add pr-made orchestrator "PR を作りました ${pr_url}" ""
review_round round-1 "$sha" code-reviewer
all_ok round-1 "$sha" code-reviewer
set_principal_pick claude-principal
final_round final-1 "$sha" round-1
result final-1 claude-principal ✅ "$sha" なし
run final-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: マージの依頼'* ]] || fail "QA の役がないのに止まっている: $(<"$test_dir/out")"
echo 'PASS review-next-decide: QA が選ばれる変更で組に QA の結果がなければ、確認を流さずにリーダーに任せる'

# ---- 状態と書けないとき。
reset
final_ok
touch "$test_dir/post-fail"
run final-1
expect_failure 'コメントの投稿に失敗した'
expect_no_calls status-calls
echo 'PASS review-next-decide: 書けないときはタスクの状態を変えない'

# ---- マージの前に人間がすること。PR の本文の `## 注意` を 1 回だけ読み、整えて、コンフリクトと CI の行のあと、各役の結論の前に置く。
plain_lines=('✅ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')
# 読む深さは、注意の状態で決まる。注意が「なし」ならコメントだけ、読めないなら注意を読めない、それ以外は注意あり。
depth_of() { # 注意の行（最初の行）
	local state=注意あり
	case $1 in
	*': なし') state=注意なし ;;
	*': 読めない（'*) state=注意を読めない ;;
	esac
	if [[ $state == 注意なし ]]; then
		printf '読む深さ: このコメントだけ（重要でない。注意なし、残した指摘 0 件、前からある不具合 0 件）'
	else
		printf '読む深さ: このコメントと PR の注意（重要でない。%s、残した指摘 0 件、前からある不具合 0 件）' "$state"
	fi
}
note_case() { # PR の本文 期待する行（複数の行は改行で続ける）
	reset
	set_roster orchestrator code-reviewer qa
	ok_round
	set_pr_body "$1"
	merge_note=$2
	merge_depth=$(depth_of "${2%%$'\n'*}")
	run round-1
	expect_merge_posted "$(merge_body round-1 "$sha" "$conf_line" "${plain_lines[@]}")"
	expect_calls body-calls 'pr view 7 --repo demo/project --json body'
}
N=マージの前に人間がすること
note_case $'## 注意\n\nなし' "${N}: なし"
note_case $'## 注意\nなし。\n## 確認\n確認した' "${N}: なし"
note_case $'## 概要\n変更\n## 注意\n\n- マージの前に評価を流し直す\n\n## 確認\nOK' "${N}: マージの前に評価を流し直す"
note_case $'## 注意\n\n1. 評価を流し直す\n2. 一覧で混入を検査する' "${N}: PR の注意の 2 行
- 評価を流し直す
- 一覧で混入を検査する"
note_case $'## 注意\r\nなし\r\n' "${N}: なし"
note_case $'## 概要\nだけ\n' "${N}: 読めない（PR の本文に注意の見出しがない）"
note_case $'## 注意\n\n## 確認\n確認した' "${N}: 読めない（PR の本文の注意が空）"
note_case '' "${N}: 読めない（PR の本文に注意の見出しがない）"
# 長い注意は、10 行か 800 字のどちらかに届く手前の行で切り、残りの行の数を示す。10 行までと 800 字までは、そのまま載せる。
ten=$(printf '手順 %s\n' 1 2 3 4 5 6 7 8 9 10)
note_case "## 注意"$'\n'"$ten" "${N}: PR の注意の 10 行
$(printf -- '- 手順 %s\n' 1 2 3 4 5 6 7 8 9 10 | sed '$d')
- 手順 10"
eleven=$(printf '手順 %s\n' 1 2 3 4 5 6 7 8 9 10 11)
note_case "## 注意"$'\n'"$eleven" "${N}: PR の注意の 11 行
$(printf -- '- 手順 %s\n' 1 2 3 4 5 6 7 8 9 10)
- 続きは PR の本文の注意を読む（残り 1 行）"
a300=$(printf 'あ%.0s' $(seq 300))
note_case "## 注意"$'\n'"$a300"$'\n'"$a300"$'\n'"$a300" "${N}: PR の注意の 3 行
- $a300
- $a300
- 続きは PR の本文の注意を読む（残り 1 行）"
a800=$(printf 'あ%.0s' $(seq 800))
note_case "## 注意"$'\n'"$a800" "${N}: $a800"
note_case "## 注意"$'\n'"${a800}あ" "${N}: ${a800:0:799}…"
echo 'PASS review-next-decide: マージの前に人間がすることは、PR の本文の注意から、なし・1 行・2 行以上・長い注意・見出しなし・空の形で、各役の結論の前に書く'

# 整える。字下げ・引用・箇条書きの記号を外し、コードの囲みと HTML の行を捨てて旨を 1 行足し、メンションのリンクは文字だけにする。
note_case $'## 注意\n\n  > - 評価を流し直す\n\t* 一覧で検査する' "${N}: PR の注意の 2 行
- 評価を流し直す
- 一覧で検査する"
note_case $'## 注意\n\n評価を流し直す\n```bash\nmake eval\n```\n<details>\n~~~\n- x\n~~~\n- 手でする' "${N}: PR の注意の 3 行
- 評価を流し直す
- 手でする
- （コードの囲みや HTML は PR の本文の注意を読む）"
note_case $'## 注意\n\n```\nだけ' "${N}: （コードの囲みや HTML は PR の本文の注意を読む）"
# 囲みは本文の先頭から追い、囲みの外の見出しだけを節の開始と終了に使う。注意より前の囲みの中の偽の `## 注意` は拾わず、注意の中のコード例の見出しで節を終えない。
drop='- （コードの囲みや HTML は PR の本文の注意を読む）'
note_case $'## 概要\n```md\n## 注意\n- 偽の作業\n```\n## 注意\n- 本物の作業' "${N}: 本物の作業"
note_case $'## 概要\n~~~md\n## 注意\n- 偽の作業\n~~~\n## 注意\n- 本物の作業' "${N}: 本物の作業"
note_case $'## 概要\n```md\n## 注意\n- 偽の作業\n```' "${N}: 読めない（PR の本文に注意の見出しがない）"
note_case $'## 注意\n```\n## サンプル\n```\n- マージの前に評価を流し直す' "${N}: PR の注意の 2 行
- マージの前に評価を流し直す
$drop"
note_case $'## 注意\n~~~\n## サンプル\n~~~\n- マージの前に評価を流し直す' "${N}: PR の注意の 2 行
- マージの前に評価を流し直す
$drop"
note_case $'## 注意\n```\n## サンプル\n- 例\n```\n- 作業\n## 確認\n- 確認' "${N}: PR の注意の 2 行
- 作業
$drop"
# 囲みの閉じは、同じ文字で、開きの長さ以上のときだけ。短い・同じ長さ・長い・文字が違う。
note_case $'## 注意\n````markdown\n```bash\n- 例\n```\nこのコードは例です\n````\n- 評価を流し直す' "${N}: PR の注意の 2 行
- 評価を流し直す
$drop"
note_case $'## 注意\n~~~~\n~~~\n- 例\n~~~\nこのコードは例です\n~~~~\n- 評価を流し直す' "${N}: PR の注意の 2 行
- 評価を流し直す
$drop"
note_case $'## 注意\n````\n- 例\n````\n- 評価を流し直す' "${N}: PR の注意の 2 行
- 評価を流し直す
$drop"
note_case $'## 注意\n```\n- 例\n`````\n- 評価を流し直す' "${N}: PR の注意の 2 行
- 評価を流し直す
$drop"
note_case $'## 注意\n```\n~~~\n- 例\n- 中\n```\n- 評価を流し直す' "${N}: PR の注意の 2 行
- 評価を流し直す
$drop"
note_case $'## 注意\n````\n- 例\n```\n## 確認\n- 中' "${N}: （コードの囲みや HTML は PR の本文の注意を読む）"
note_case $'## 注意\n\n@する人 [@Agent](mention://agent/agent-9) に聞く\nmention://agent/agent-9 は残る' "${N}: PR の注意の 2 行
- @する人 @Agent に聞く
- mention: //agent/agent-9 は残る"
# 6-2: 写しても、エージェントへのメンションが生まれない。呼ぶ人間のリンクだけが残る。
[[ $(grep -o 'mention://' <<<"$(posted_body)" | wc -l | tr -d ' ') == 1 ]] || fail "mention:// が 1 つでない: $(posted_body)"
[[ $(posted_body) != *'mention://agent/'* ]] || fail "エージェントへのメンションがある: $(posted_body)"
echo 'PASS review-next-decide: 注意の字下げ・引用・記号・コードの囲み・HTML・メンションのリンクを整え、写した本文にも mention:// が呼ぶ人間の 1 つだけ残る'

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
