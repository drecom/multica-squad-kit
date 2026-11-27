#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-review-next-decide-rework-record-merge-test.sh で実行する。
# この部分は、マージの依頼へ進む経路で、長い本文を読んでも共有の判定の起動が増えないことを確認する。
# 記録を読む場面と、decide が共有の判定を重複して起こさないことを確認する。
set -euo pipefail
source "$(dirname "$0")/review-next-decide-common.sh"
source "$(dirname "$0")/review-next-decide-rework-record-lib.sh"

# ---- マージの依頼へ進む経路。⚠️ の要約の長い 1 項目と、PR の本文の長い 1 行を、2 つの場面で通す。
# 長い 1 行の中身は、閉じたコードスパン（`a`）の繰り返し、長さの違う閉じていない逆引用符の並び、行頭の長い記号列（引用・箇条書き・番号・空白）にする。
# 囲みとコメントを見分ける走査が、行の長さに比例して終わるかを測る。
body_chars=65536
make_merge_scale() { # 場面（closed | unclosed | quote | bullet | number | space | bracket）
	"$REWORK_RECORD_REAL_PYTHON" -I - "$test_dir" "$1" "$scale_comments" "$scale_bytes" "$body_chars" <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
scene = sys.argv[2]
count, minimum, body_chars = map(int, sys.argv[3:])
marker = '@@ITEM@@'


def long_line(length):
    marks = {'quote': '>', 'bullet': '- ', 'number': '1) ', 'space': ' ', 'bracket': '['}
    if scene in marks:
        # 行頭の記号だけが長く続く 1 行。外す処理が、記号を 1 つ外すたびに残りを写すと 2 乗で伸びる。
        text = marks[scene] * ((length - 1) // len(marks[scene]))  # 末尾に文字を残し、前後の空白を削る処理で長さが変わらないようにする
    elif scene == 'closed':
        # 空白で区切り、コードスパンを 1 つずつ閉じる。区切らないと、隣り合う逆引用符が 2 個の並びになり、全体が 1 つのスパンに読まれる。
        text = '`a` ' * (length // 4)
    else:
        # 同じ長さの並びは 1 度しか出さないので、どの逆引用符も閉じない。
        parts, size, run = [], 0, 1
        while size + 1 + run <= length:
            parts.append('a' + '`' * run)
            size += 1 + run
            run += 1
        text = ''.join(parts)
    text += 'a' * (length - len(text))
    assert len(text) == length
    return text


path = root / 'comments.json'
comments = json.loads(path.read_text())
if count < len(comments):
    raise SystemExit('規模の件数は、場面の準備のコメントを置ける数にする')
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
holders = [c for c in comments if marker in c['content']]
assert len(holders) == 1 and len(comments) == count
base = sum(len(c['content'].replace(marker, '').encode('utf-8')) for c in comments)
item = long_line(max(minimum - base, 3))
holders[0]['content'] = holders[0]['content'].replace(marker, item)
size = sum(len(c['content'].encode('utf-8')) for c in comments)
assert size >= minimum
path.write_text(json.dumps(comments, ensure_ascii=False))
head = '## 注意\n\n- '
(root / 'scale-body').write_text(head + long_line(body_chars - len(head)))
print(len(comments), size)
PY
}
check_merge_counts() {
	"$REWORK_RECORD_REAL_PYTHON" -I - "$test_dir" >"$test_dir/metrics" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
calls = [line.split('\t') for line in (root / 'python-calls').read_text().splitlines()]
analyze = sum(shared == '1' and mode == 'analyze' for shared, _, mode in calls)
note = sum(shared == '2' for shared, _, _ in calls)
source_args = sum(source == '1' for _, source, _ in calls)
if analyze != 1 or note != 1 or source_args != 0:
    raise SystemExit(f'共有の判定の analyze: {analyze} 回（期待 1）、注意を整える処理: {note} 回（期待 1）、ソースを引数に持つ起動: {source_args} 回（期待 0）')
times = [line.split('\t') for line in (root / 'python-times').read_text().splitlines()]
shared = [float(seconds) for source, mode, seconds in times if source == '1' and mode == 'analyze']
decide = [float(seconds) for source, mode, seconds in times if source == '0' and mode == 'analyze']
note = [float(seconds) for source, _, seconds in times if source == '2']
if len(shared) != 1 or len(decide) != 1 or len(note) != 1:
    raise SystemExit('時間の対象の共有の判定、decide の判定、注意の整え方が 1 回ずつでない')
print(f'{shared[0]:.3f} {decide[0]:.3f} {note[0]:.3f} {shared[0] + decide[0] + note[0]:.3f}')
PY
}
for scene in closed unclosed quote bullet number space bracket; do
	case $scene in
	closed) label=閉じたコードスパン ;;
	unclosed) label=閉じていない逆引用符 ;;
	quote) label=長い引用記号 ;;
	bullet) label=長い箇条書きの記号 ;;
	number) label=長い番号の記号 ;;
	space) label=長い空白 ;;
	bracket) label=長い開き角括弧 ;;
	esac
	reset
	set_merge_roster
	ok_round
	final_round final-1 "$sha" round-1
	result final-1 claude-principal ⚠️ "$sha" なし 推奨 $'指摘の一覧: 1 件\n- @@ITEM@@'
	make_merge_scale "$scene" >"$test_dir/scale-size"
	read -r count bytes <"$test_dir/scale-size"
	set_pr_body "$(<"$test_dir/scale-body")"
	[[ $(jq -j .body "$test_dir/body.json" | wc -m | tr -d " ") -eq $body_chars ]] || fail "PR の本文が $body_chars 字でない"
	: >"$test_dir/python-calls"
	: >"$test_dir/python-times"
	run final-1
	expect_status 0
	[[ $(jq -s length "$test_dir/posted.jsonl") == 1 ]] || fail "コメントが 1 件でない: $(<"$test_dir/posted.jsonl")"
	[[ $(<"$test_dir/out") == $'次の依頼: マージの依頼\n依頼: posted-comment' ]] || fail "行き先がマージの依頼でない: $(<"$test_dir/out")"
	posted=$(posted_body)
	[[ $posted == '[@Owner](mention://member/human-1) レビューと確認が済みました。'* ]] || fail "マージの依頼でない: ${posted:0:300}"
	[[ $(sed -n 2p <<<"$posted") == "マージの依頼: $sha" ]] || fail "マージの依頼の行が違う: ${posted:0:300}"
	[[ $posted != *'読む深さ: このコメントだけ'* ]] || fail "長い 1 行の注意を「なし」として、読む深さを縮めた"
	check_merge_counts
	read -r shared_time decide_time note_time total_time <"$test_dir/metrics"
	printf 'PASS merge-scale: コメント %s 件、本文 %s バイト、PR の本文 %s 字、マージ %s、行き先はマージの依頼、処理の数が一致\n' "$count" "$bytes" "$body_chars" "$label"
	printf '測定: コメント %s 件、本文 %s バイト、マージ %s、共有の判定 %s 秒、decide の判定 %s 秒、注意の整え方 %s 秒、合計 %s 秒\n' "$count" "$bytes" "$label" "$shared_time" "$decide_time" "$note_time" "$total_time"
done
