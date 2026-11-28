#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-rework-record-test.sh で実行する。
# この部分は、手戻りの見直しの記録を読む場面と、共有の判定の起動の数を確認する。
# 記録を読む場面と、decide が共有の判定を重複して起こさないことを確認する。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
source "$(dirname "$0")/review-next-decide-rework-record-lib.sh"

failed_round
add record orchestrator "$record"
jq 'map(if .id == "record" then .author_type = "member" else . end)' "$test_dir/comments.json" >"$test_dir/comments.new"
mv "$test_dir/comments.new" "$test_dir/comments.json"
run round-1
expect_record_stop
echo 'PASS rework-record: リーダーと同じ ID のメンバーの行では止まる'

failed_round
add record orchestrator "文の途中に $record"
run round-1
expect_record_stop
echo 'PASS rework-record: 行頭でなく文の途中にある行では止まる'

failed_round
jq --arg record "$record" '.description += ("\n" + $record)' "$test_dir/issue.json" >"$test_dir/issue.new"
mv "$test_dir/issue.new" "$test_dir/issue.json"
run round-1
expect_record_stop
echo 'PASS rework-record: タスクの本文だけにある行では止まる'

failed_round
add unreadable-record orchestrator $'> 引用\n'"$record"
add readable-comment orchestrator '記録はまだない'
run round-1
expect_record_stop
echo 'PASS rework-record: 読めない本文のほうだけにある行では止まる'

failed_round
add unreadable-record orchestrator $'> 引用\n'"$record"
add readable-record orchestrator "$record"
run round-1
expect_posted 修正 "$(fix_body)"
echo 'PASS rework-record: 読めない本文と読める本文の両方に行があれば修正を頼む'

reset
add other-thread human-1 '別の話題' ''
add early-record orchestrator "$record" other-thread
base_round
add design-change human-1 '設計の変更: 実装を始めたあと'
result round-1 code-reviewer ❌ "$sha" なし
result round-1 qa ✅ "$sha" なし
run round-1
expect_posted 修正 "$(fix_body)"
echo 'PASS rework-record: 回より前の別スレッドの返信にある行でも修正を頼む'


make_scale() {
	"$REWORK_RECORD_REAL_PYTHON" -I - "$test_dir/comments.json" "$scale_comments" "$scale_bytes" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
count, minimum = map(int, sys.argv[2:])
comments = json.loads(path.read_text())
if count < len(comments) + 4 or minimum < 0:
    raise SystemExit('規模の件数は種のコメントと 4 種の見本を置ける数、バイト数は 0 以上にする')
examples = [
    '囲みの見本\n```text\n手戻りの見直し: 見本\n```',
    '> 手戻りの見直し: 見本',
    '- 手戻りの見直し: 見本',
    '<!--\n手戻りの見直し: 見本\n-->',
]
authors = [('orchestrator', 'agent'), ('qa', 'agent'), ('human-1', 'member')]
template = comments[0]
for i in range(count - len(comments)):
    author, kind = authors[i % len(authors)]
    comments.append(template | {
        'id': f'scale-{i}', 'author_id': author, 'author_type': kind,
        'content': examples[i % len(examples)], 'created_at': '2026-11-10T10:00:00Z',
        'parent_id': 'other-thread',
    })
size = sum(len(c['content'].encode('utf-8')) for c in comments)
if size < minimum:
    comments[-1]['content'] += '\n' + 'x' * (minimum - size - 1)
size = sum(len(c['content'].encode('utf-8')) for c in comments)
assert len(comments) == count and size >= minimum
path.write_text(json.dumps(comments, ensure_ascii=False))
print(len(comments), size)
PY
}
check_counts() {
	"$REWORK_RECORD_REAL_PYTHON" -I - "$test_dir" >"$test_dir/metrics" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
calls = [line.split('\t') for line in (root / 'python-calls').read_text().splitlines()]
analyze = sum(shared == '1' and mode == 'analyze' for shared, _, mode in calls)
source_args = sum(source == '1' for _, source, _ in calls)
if analyze != 1 or source_args != 0:
    raise SystemExit(f'共有の判定の analyze: {analyze} 回（期待 1）、ソースを引数に持つ起動: {source_args} 回（期待 0）')
times = [line.split('\t') for line in (root / 'python-times').read_text().splitlines()]
shared = [float(seconds) for source, mode, seconds in times if source == '1' and mode == 'analyze']
decide = [float(seconds) for source, mode, seconds in times if source == '0' and mode == 'analyze']
if len(shared) != 1 or len(decide) != 1:
    raise SystemExit('時間の対象の共有の判定と decide の判定が 1 回ずつでない')
print(f'{shared[0]:.3f} {decide[0]:.3f} {shared[0] + decide[0]:.3f}')
PY
}
for mark in ❌ ✅; do
	reset
	base_round
	add design-change human-1 '設計の変更: 実装を始めたあと'
	add record orchestrator "$record"
	result round-1 code-reviewer "$mark" "$sha" なし
	result round-1 qa ✅ "$sha" なし
	if [[ $mark == ✅ ]]; then set_principal_pick claude-principal; fi
	make_scale >"$test_dir/scale-size"
	read -r count bytes <"$test_dir/scale-size"
	: >"$test_dir/python-calls"
	: >"$test_dir/python-times"
	run round-1
	if [[ $mark == ❌ ]]; then
		expect_posted 修正 "$(fix_body)"
		failed=あり
	else
		expect_posted 最終レビュー "$(final_request_body 'PR の差分全体')"
		failed=なし
	fi
	check_counts
	read -r shared_time decide_time total_time <"$test_dir/metrics"
	printf 'PASS rework-count: ❌ %s、analyze 1 回、ソースを引数に持つ起動 0 回\n' "$failed"
	printf 'PASS rework-scale: コメント %s 件、本文 %s バイト、❌ %s、行き先と処理の数が一致\n' "$count" "$bytes" "$failed"
	printf '測定: コメント %s 件、本文 %s バイト、❌ %s、共有の判定 %s 秒、decide の判定 %s 秒、合計 %s 秒\n' "$count" "$bytes" "$failed" "$shared_time" "$decide_time" "$total_time"
done
