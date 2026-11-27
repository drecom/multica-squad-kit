#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-merge-note-test.sh で実行する。
# この部分は、PR の本文の注意を読む条件と、長い注意の切り方を確認する。
# squad-review-next decide のマージの依頼に書く注意・読む深さ・残した指摘・前からある不具合を確認する。準備は tests/review-next-decide-common.sh にある。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
source "$(dirname "$0")/review-next-decide-merge-note-lib.sh"

# ---- マージの前に人間がすること。PR の本文の `## 注意` を 1 回だけ読み、整えて、コンフリクトと CI の行のあと、各役の結論の前に置く。

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
