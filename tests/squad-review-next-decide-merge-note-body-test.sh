#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-merge-note-body-test.sh で実行する。
# この部分は、注意の整え方（字下げ・引用・囲み・HTML・メンション）を確認する。
# squad-review-next decide のマージの依頼に書く注意・読む深さ・残した指摘・前からある不具合を確認する。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
source "$(dirname "$0")/review-next-decide-merge-note-lib.sh"

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
# HTML コメント。コメントの中の見出しは、節の始まりにも終わりにも使わない（表: docs/merge-request-reading.md の「注意の入力の種類と写し方」。全行は tests/review-note-table-test.sh）。
note_case $'## 概要\n<!--\n## 注意\nなし\n## 記入例はここまで -->\n## 注意\n- マージの前にバックアップする' "${N}: マージの前にバックアップする"
note_case $'## 注意\n<!--\n## 記入例\n-->\n- マージの前にバックアップする\n- 評価を流し直す' "${N}: PR の注意の 3 行
- マージの前にバックアップする
- 評価を流し直す
$drop"
note_case $'## 注意\n- 作業\n<!--\n## 確認\n- 例' "${N}: PR の注意の 2 行
- 作業
$drop"
note_case $'## 注意\n<!-- なし -->' "${N}: （コードの囲みや HTML は PR の本文の注意を読む）"
note_case $'## 注意\n\n@する人 [@Agent](mention://agent/agent-9) に聞く\nmention://agent/agent-9 は残る' "${N}: PR の注意の 2 行
- @する人 @Agent に聞く
- mention: //agent/agent-9 は残る"
# 6-2: 写しても、エージェントへのメンションが生まれない。呼ぶ人間のリンクだけが残る。
[[ $(grep -o 'mention://' <<<"$(posted_body)" | wc -l | tr -d ' ') == 1 ]] || fail "mention:// が 1 つでない: $(posted_body)"
[[ $(posted_body) != *'mention://agent/'* ]] || fail "エージェントへのメンションがある: $(posted_body)"
echo 'PASS review-next-decide: 注意の字下げ・引用・記号・コードの囲み・HTML・メンションのリンクを整え、写した本文にも mention:// が呼ぶ人間の 1 つだけ残る'
