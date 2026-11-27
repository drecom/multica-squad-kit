# squad-review-next-decide-rework-record*-test.sh が読み込む共通の準備（python3 の包み・共有の判定のソース・補助）。単独では実行しない。
# review-next-decide-common.sh を読み込んだあとで読み込む。
# 包みを置く前の Python を使う。共有の判定のソースは、改行も含めてそのまま比較する。
export REWORK_RECORD_REAL_PYTHON
REWORK_RECORD_REAL_PYTHON=$(command -v python3)
printf '%s\0' "$SQUAD_CLI_CONTROL_PY" >"$test_dir/control-source"
# 注意を整える処理（NOTE_PY）のソースは、スクリプトの定義を同じ読み方で取り出して、-c に渡る文と同じにする。
extract_py() { sed -n "/^read -r -d '' $1 <</,/^$2\$/p" "$test_dir/monitor/squad-review-next"; }
note_source=$(
	eval "$(extract_py MARKUP_PY MARKUPPY)"
	eval "$(extract_py NOTE_PY NOTEPY)"
	printf '%s' "${MARKUP_PY}"$'\n'"${NOTE_PY}"
)
[[ -n $note_source ]] || fail '注意を整える処理のソースを取り出せない'
printf '%s\0' "$note_source" >"$test_dir/note-source"
cat >"$test_dir/bin/python3" <<'WRAP'
#!/usr/bin/env bash
set -u
dir=$REVIEW_NEXT_TEST_DIR
IFS= read -r -d '' control_source <"$dir/control-source"
IFS= read -r -d '' note_source <"$dir/note-source"
program= mode= shared=0 source_arg=0 after_program=0 want_program=0 want_mode=0
for arg in "$@"; do
	if ((want_program)); then
		program=$arg
		want_program=0 after_program=1 want_mode=1
	elif ((after_program)); then
		if ((want_mode)); then mode=$arg; want_mode=0; fi
		if [[ $arg == "$control_source" ]]; then source_arg=1; fi
	elif [[ $arg == -c ]]; then
		want_program=1
	fi
done
# 共有の判定は 1、注意を整える処理は 2、それ以外は 0 と記録する。
if [[ $program == "$control_source" ]]; then
	shared=1
elif [[ $program == "$note_source" ]]; then
	shared=2
fi
# 引数がソースそのものでも、記録は起動ごとに 1 行にする。
mode=${mode//\\/\\\\}
mode=${mode//$'\t'/\\t}
mode=${mode//$'\n'/\\n}
mode=${mode//$'\r'/\\r}
printf '%s\t%s\t%s\n' "$shared" "$source_arg" "$mode" >>"$dir/python-calls"
export LC_NUMERIC=C
TIMEFORMAT=%R
timing="$dir/python-time.$$"
status=0
# 子の標準エラーは元の出力先に返し、time の秒だけを別に読む。
{ time "$REWORK_RECORD_REAL_PYTHON" "$@" 2>&3; } 3>&2 2>"$timing" || status=$?
printf '%s\t%s\t%s\n' "$shared" "$mode" "$(<"$timing")" >>"$dir/python-times"
rm -f "$timing"
exit "$status"
WRAP
chmod +x "$test_dir/bin/python3"

# 引数にソースを持つ起動を、プログラムとしての起動と区別できることも確認する。
: >"$test_dir/python-calls"
python3 -I -c 'pass' "$SQUAD_CLI_CONTROL_PY"
awk -F '\t' '$1 == 0 && $2 == 1 {found++} END {exit(found != 1)}' "$test_dir/python-calls" \
	|| fail '共有の判定のソースを引数に持つ起動を記録できない'

record='手戻りの見直し: 頼まない。合図: 設計の変更。理由: テスト'
design_stop='設計の変更が実装を始めたあとで、マークも 手戻りの見直し: もない（手戻りの見直しの判断）'
failed_round() {
	reset
	base_round
	add design-change human-1 '設計の変更: 実装を始めたあと'
	result round-1 code-reviewer ❌ "$sha" なし
	result round-1 qa ✅ "$sha" なし
}
fix_body() {
	printf '%s PR の ❌ の指摘を直してください。\n前の回: round-1\n修正の依頼: 1 回目\n振り分け: Claude で足りる。工程: fix\n直す指摘: code-reviewer（結果は、この回の返事のコメントと PR のコメントにある）\n対象の PR: %s' "$(mention claude-fixer)" "$pr_url"
}
expect_record_stop() {
	expect_leader "$design_stop"
	[[ $(<"$test_dir/out") == "次の依頼を決められません: $design_stop" ]] || fail '止まる理由の行が変わった'
	expect_no_calls pick-calls
}
# 既存の見本を種にし、件数をちょうど指定値、本文を指定バイト数以上にする。
# 判定を止めない正式な記録は 1 つだけで、見本の行は囲み・引用・項目・HTML の中に置く。
scale_comments=${REVIEW_NEXT_TEST_SCALE_COMMENTS:-20}
scale_bytes=${REVIEW_NEXT_TEST_SCALE_BYTES:-20000}
