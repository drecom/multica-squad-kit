#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-control-resume-test.sh で実行する。準備は tests/review-next-decide-common.sh にある。
# この部分は、答えのあとの流し直し・「進める」「待つ」の記録・道の記録を確認する。
# squad-review-next decide の判定のうち、制御記録（書き済みとするか）を確認する。
# 条件は docs/review-next-step.md の「制御記録の読み方」にある。認める回と最終レビューの認め方は squad-review-next-decide-recognize-test.sh。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
reset

written() { # 何も書かず、書き済みを出す
	expect_status 0
	[[ $(<"$test_dir/out") == '次の依頼: 書き済み' ]] || fail "書き済みを出していない: $(<"$test_dir/out")"
	expect_nothing_written
}
not_written() { # 書き済みにせず、次の依頼を 1 回書く
	expect_status 0
	[[ $(<"$test_dir/out") != '次の依頼: 書き済み' ]] || fail "書き済みにしている"
	[[ $(jq -s length "$test_dir/posted.jsonl") == 1 ]] || fail "次の依頼が 1 件でない: $(<"$test_dir/posted.jsonl")"
}

human_new_line=$'使用率の待ち: fix は 2026-11-12T03:00:00Z まで待つと通算 24 時間を超える。待ち始め: 2026-11-11T03:00:00Z。Claude 週 90%'

# decide が人間を呼んだ回は、答えのあとに同じ回の decide を流し直しても、書き済みで終わり、依頼も起こしも人間の呼び出しも増えない。
# 3 つの答えのどれでも、人間を呼ぶコメントは同じなので、続きはリーダーが手で頼む。
fix_round() { # ❌ の回 round-1
	reset
	base_round
	result round-1 code-reviewer ❌ "$sha" なし
	result round-1 qa ✅ "$sha" なし
}
fix_round
printf '%s\n' "$human_new_line" >"$test_dir/pick-out"
echo 4 >"$test_dir/pick-status"
run round-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 人間の確認\n依頼: posted-comment' ]] || fail "人間の呼びの出力が違う: $(<"$test_dir/out")"
human_body=$(posted_body)
[[ $human_body == *'「待つ」「進める」「利用枠を足した」のどれかを返事してください。'* ]] || fail "人間の呼びに 3 つの答えがない: $human_body"
for author in orchestrator qa; do
	fix_round
	[[ $author != qa ]] || add decide-qa qa $'/note\n返事の待ち: 次の依頼を決めます'
	add human-call "$author" "$human_body"
	add human-answer human-1 '進める'
	run round-1
	written || fail "$author が書いた人間を呼ぶコメントのあと、同じ回の decide が書き済みにならない"
	expect_no_calls status-calls
done
echo 'PASS review-next-decide: decide が人間を呼んだ回は、答えのあとに流し直しても書き済みで終わり、何も書かない'

# decide を呼ぶ前から「進める」の記録が効いている回は、pick が終了 0 を返す。人間を呼ばず、次の依頼を 1 回書き、振り分けの行に 1 文を足す。
proceed_line=$'振り分け: Claude（Codex は週の使用率が 80% 以上）。Claude 週 90%（使ってよい量 62%）。人間の答えで進める（期限 2026-11-12T03:00:00Z、答えのタスク DEMO-90）。工程: fix'
fix_round
printf '役: claude-fixer\n%s\n' "$proceed_line" >"$test_dir/pick-out"
echo 0 >"$test_dir/pick-status"
run round-1
expect_status 0
[[ $(<"$test_dir/out") == $'次の依頼: 修正'* ]] || fail "「進める」で修正の依頼を書いていない: $(<"$test_dir/out")"
[[ $(jq -s length "$test_dir/posted.jsonl") == 1 ]] || fail "依頼が 1 件でない: $(<"$test_dir/posted.jsonl")"
body=$(posted_body)
[[ $body == *$'\n'"$proceed_line"$'\n'* || $body == *$'\n'"$proceed_line" ]] || fail "依頼に 1 文を足した振り分けの行がない: $body"
[[ $body != *'通算 24 時間を超えます'* ]] || fail "「進める」なのに人間を呼んでいる: $body"
expect_no_calls status-calls
echo 'PASS review-next-decide: 「進める」の記録が効いている回は、人間を呼ばずに次の依頼を書き、振り分けの行に答えの 1 文を足す'

# 「待つ」の記録が効いている回は、pick が終了 3 を返す。待ちのコメントだけを書き、人間を呼ばず、状態も変えない。
wait_line=$'使用率の待ち: fix を 2026-11-12T03:00:00Z まで待つ。待ち始め: 2026-11-11T03:00:00Z。Claude 週 90%。人間の答えで待つ（期限 2026-11-12T03:00:00Z、答えのタスク DEMO-90）'
fix_round
printf '%s\n' "$wait_line" >"$test_dir/pick-out"
echo 3 >"$test_dir/pick-status"
run round-1
expect_posted '使用率の待ち' "$wait_line"$'\n前の回: round-1'
expect_no_calls status-calls
echo 'PASS review-next-decide: 「待つ」の記録が効いている回は、待ちのコメントだけを書き、人間を呼ばず、状態も変えない'

# 道の記録は共有の解析で読み、リーダーの読める本文の行だけを使う。
path_value() {
	squad_cli_control analyze "$(<"$test_dir/comments.json")" '["orchestrator"]' '[]' | jq -e --argjson want "$1" '.short_path == $want' >/dev/null \
		|| fail "short_path が $1 でない"
}
reset
path_value false
add path-short orchestrator '道: 短い'
path_value true
add path-other qa '道: 通常'
path_value true
add path-normal orchestrator '道: 通常'
path_value false
# 時刻順で最新の記録を選び、配列の並びに依存しない。
jq 'reverse' "$test_dir/comments.json" >"$test_dir/comments.new"
mv "$test_dir/comments.new" "$test_dir/comments.json"
path_value false
for author in qa human-1; do
	reset
	add path "$author" '道: 短い'
	path_value false
done
# author_id が同じでも、人間が書いたものは読まない。
reset
add path orchestrator '道: 短い'
jq '.[0].author_type = "member"' "$test_dir/comments.json" >"$test_dir/comments.new"
mv "$test_dir/comments.new" "$test_dir/comments.json"
path_value false
for text in $'```\n道: 短い\n```' '> 道: 短い' '- 道: 短い' '    道: 短い' $'```\n道: 短い'; do
	reset
	add path orchestrator "$text"
	path_value false
done
for text in '道:' '道: 不明' '道: 短い（人間の同意を得た）'; do
	reset
	add path-short orchestrator '道: 短い'
	add path-invalid orchestrator "$text"
	path_value false
done
reset
add path orchestrator $'/note 道: 短い\r\n'
path_value true
echo 'PASS review-next-decide: 道の記録は作者と置き方を確認し、最新の値だけを使う'

# 共有の解析から欄が欠けたり真偽でない値が返ったら、何も書かずに失敗する。
# 自分のテスト用に写した部品だけを変え、CLI の実物の見本は変えない。
cp "$test_dir/monitor/squad-cli-lib" "$test_dir/control-original"
for value in missing null '"true"' 1; do
	reset
	ok_round
	python3 - "$test_dir/control-original" "$test_dir/monitor/squad-cli-lib" "$value" <<'PYVALUE'
import sys
from pathlib import Path
source, target, value = sys.argv[1:]
text = Path(source).read_text()
line = '        "short_path": short_path,\n'
assert text.count(line) == 1
value = 'None' if value == 'null' else value
replacement = '' if value == 'missing' else f'        "short_path": {value},\n'
Path(target).write_text(text.replace(line, replacement))
PYVALUE
	run round-1
	expect_failure '返事の組を読めない'
	expect_nothing_written
done
cp "$test_dir/control-original" "$test_dir/monitor/squad-cli-lib"
echo 'PASS review-next-decide: short_path の欠けと読めない値では、何も書かずに失敗する'
