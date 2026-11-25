#!/usr/bin/env bash
# 役ごとの毎回読む文の大きさが上限以下であること、分ける前の規則の本文の行が残っていることと、その検査が働くことを確認する。設計は docs/usage-reduction.md の「大きさのテスト」と「規則を残す確認」。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/base-size.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
fixture="$root/tests/fixtures/base-size"
check() { python3 "$root/tests/base-size-check.py" "$@"; }

check size "$root" "$fixture"
echo 'PASS base-size: 共通スキルの本体と役ごとの大きさは、上限以下である'
check lines "$root" "$fixture"
echo 'PASS base-size: 分ける前の本文の行は、同じ数だけ残っているか、変えた行の一覧にある'

# 検査の入力の写しを作る。原本の根は、大きさを測るファイルだけを写す。
copy_root() {
	local dst=$1
	mkdir -p "$dst/common/skills/squad-handoff" "$dst/tests"
	cp -R "$root/common/agents" "$dst/common/agents"
	cp "$root/common/skills/squad-handoff/SKILL.md" "$dst/common/skills/squad-handoff/"
	cp -R "$root/common/skills/squad-handoff/references" "$dst/common/skills/squad-handoff/references"
	cp -R "$fixture" "$dst/fixture"
}
expect_fail() {
	local label=$1 mode=$2 dir=$3 needle=$4
	if check "$mode" "$dir" "$dir/fixture" >"$test_dir/out" 2>"$test_dir/err"; then
		echo "FAIL base-size: 通ってしまった: $label" >&2
		exit 1
	fi
	grep -qF -- "$needle" "$test_dir/err" || { echo "FAIL base-size: 出力に「$needle」がない: $label" >&2; cat "$test_dir/err" >&2; exit 1; }
}

# 共通スキルの本体が上限を超えたら、今の大きさと上限を出して落ちる。
d="$test_dir/skill-over"
copy_root "$d"
python3 -c 'import sys; open(sys.argv[1], "a").write("あ" * 1000)' "$d/common/skills/squad-handoff/SKILL.md"
expect_fail '共通スキルの本体が上限を超える' size "$d" 'FAIL skill SKILL.md: 今の大きさ'
grep -qF '上限 16000' "$test_dir/err" || { echo 'FAIL base-size: 上限を出していない' >&2; exit 1; }

# 役の指示が上限を超えたら、役の名前を出して落ちる。
d="$test_dir/role-over"
copy_root "$d"
python3 -c 'import sys; open(sys.argv[1], "a").write("あ" * 12000)' "$d/common/agents/planner.md"
expect_fail '役の指示が上限を超える' size "$d" 'FAIL role planner: 今の大きさ'
grep -qE 'FAIL role [a-z-]+: 今の大きさ [0-9]+、上限 27790' "$test_dir/err" || { echo 'FAIL base-size: 役の上限の値が違う' >&2; cat "$test_dir/err" >&2; exit 1; }

# 見張りの役は対象外で、大きくても落ちない。
d="$test_dir/monitor-over"
copy_root "$d"
python3 -c 'import sys; open(sys.argv[1], "a").write("あ" * 30000)' "$d/common/agents/ci-monitor.md"
check size "$d" "$d/fixture"

# リーダーの場面と手順の表にあってフィクスチャにない場面の行は、場面の名前を出して落ちる。
d="$test_dir/scene-missing"
copy_root "$d"
python3 - "$d/common/agents/orchestrator.md" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().split('\n')
i = lines.index('## 場面と手順')
j = next(k for k in range(i, len(lines)) if lines[k].startswith('| ') and not lines[k].startswith('| 場面'))
lines.insert(j, '| 新しい場面のテスト | 条件 | `leader-request.md` |')
open(p, 'w').write('\n'.join(lines))
PY
expect_fail 'フィクスチャにない場面の行' size "$d" 'FAIL 場面 新しい場面のテスト: フィクスチャにない場面'

# 場面は、読む参照の大きさの和が上限を超えたら、場面の名前と上限を添えて落ちる。
d="$test_dir/scene-over"
copy_root "$d"
python3 -c 'import sys; open(sys.argv[1], "a").write("あ" * 3000)' "$d/common/skills/squad-handoff/references/leader-run-stop.md"
expect_fail '場面の大きさが上限を超える' size "$d" 'FAIL scene 実行の停止: 今の大きさ'
grep -qE 'FAIL scene 実行の停止: 今の大きさ [0-9]+、上限 6289' "$test_dir/err" || { echo 'FAIL base-size: 場面の上限の値が違う' >&2; cat "$test_dir/err" >&2; exit 1; }

# 場面が読む参照が複数あるときは、その和で比べる。
d="$test_dir/scene-sum"
copy_root "$d"
python3 -c 'import sys; open(sys.argv[1], "a").write("あ" * 8000)' "$d/common/skills/squad-handoff/references/leader-principal-pick.md"
expect_fail '場面の参照の和が上限を超える' size "$d" 'FAIL scene 最上位の役に診断を頼む: 今の大きさ'

# 場面の表が読む参照がなければ、場面の名前と参照を出して落ちる。
d="$test_dir/scene-ref-missing"
copy_root "$d"
rm "$d/common/skills/squad-handoff/references/leader-review-stuck.md"
expect_fail '読む参照がない' size "$d" 'FAIL 場面 `decide` が決められない: 読む参照 leader-review-stuck.md がない'

# 場面の上限が基準の半分（切り捨て）でなければ落ちる。
d="$test_dir/scene-limit"
copy_root "$d"
sed -i.bak 's/^\(scene\t実行の停止\t12578\t\)6289\t/\16290\t/' "$d/fixture/baseline.tsv"
rm -f "$d/fixture/baseline.tsv.bak"
expect_fail '場面の上限が基準の半分でない' size "$d" '実行の停止 の上限が基準の半分'

# 扱いは 適用 か 対象外 のどちらかで、未適用は使えない。
d="$test_dir/treat-unknown"
copy_root "$d"
sed -i.bak 's/^\(scene\t実行の停止\t.*\t\)適用\t/\1未適用\t/' "$d/fixture/baseline.tsv"
rm -f "$d/fixture/baseline.tsv.bak"
expect_fail '扱いが 適用 でも 対象外 でもない行' size "$d" '扱いが 適用、対象外 のどれでもない'

# 扱いが対象外の行には、理由が要る。
d="$test_dir/no-reason"
copy_root "$d"
python3 - "$d/fixture/baseline.tsv" <<'PY'
import sys
p = sys.argv[1]
out = []
for l in open(p).read().split('\n'):
    if l.startswith('role\tci-monitor\t'):
        l = '\t'.join(l.split('\t')[:5] + [''])
    out.append(l)
open(p, 'w').write('\n'.join(out))
PY
expect_fail '理由のない対象外の行' size "$d" 'FAIL フィクスチャ baseline.tsv'
echo 'PASS base-size: 上限を超える役と場面、フィクスチャにない場面、理由のない行は、名前と大きさを添えて落ち、見張りの役は対象外になる'

# 分ける前の本文の行が消えたら、その行を出して落ちる。
d="$test_dir/line-lost"
copy_root "$d"
lost=$(sed -n '/^- 事実: /p' "$d/common/skills/squad-handoff/SKILL.md" | head -n 1)
test -n "$lost"
grep -vxF -- "$lost" "$d/common/skills/squad-handoff/SKILL.md" >"$d/skill.new"
mv "$d/skill.new" "$d/common/skills/squad-handoff/SKILL.md"
expect_fail '本文の行が消える' lines "$d" '減ったが、変えた行の一覧にない'
grep -qF -- "$lost" "$test_dir/err" || { echo 'FAIL base-size: 消えた行を出していない' >&2; exit 1; }

# 見出しが残っても、節の中の文が消えたら落ちる。
d="$test_dir/body-lost"
copy_root "$d"
python3 - "$d/common/skills/squad-handoff/references/pr.md" <<'PY'
import sys
p = sys.argv[1]
lines = open(p).read().split('\n')
i = lines.index('## PR の状態を書く')
j = next(k for k in range(i + 1, len(lines)) if lines[k].startswith('- ') and '未確認' in lines[k])
del lines[j]
open(p, 'w').write('\n'.join(lines))
PY
expect_fail '見出しを残して節の中の文が消える' lines "$d" '減ったが、変えた行の一覧にない'

# 同じ行が何度もある固定の行は、数が減っても落ちる。
d="$test_dir/count-lost"
copy_root "$d"
dup=$(grep -h -v '^$' "$fixture/rule-lines.txt" | sort | uniq -d | head -n 1)
test -n "$dup"
python3 - "$d" "$dup" <<'PY'
import sys, pathlib
root, dup = pathlib.Path(sys.argv[1]), sys.argv[2]
files = [root / 'common/skills/squad-handoff/SKILL.md'] + sorted((root / 'common/skills/squad-handoff/references').glob('*.md'))
for f in files:
    lines = f.read_text().split('\n')
    for i, l in enumerate(lines):
        if l.rstrip().lstrip('#').lstrip() == dup.lstrip() or l.rstrip() == dup:
            del lines[i]
            f.write_text('\n'.join(lines))
            raise SystemExit(0)
raise SystemExit(1)
PY
expect_fail '同じ行の数が減る' lines "$d" '減ったが、変えた行の一覧にない'

# 同じ行が増えたときは、変えた行の一覧に写したと書かなければ落ちる。
d="$test_dir/line-copied"
copy_root "$d"
printf '\n%s\n' "$lost" >>"$d/common/skills/squad-handoff/references/pr.md"
expect_fail '本文の行が増える' lines "$d" '増えたが、変えた行の一覧にない'

# 変えた行の一覧の行は、理由がなければ落ち、数が変わっていない行を載せても落ち、後の行が見つからなくても落ちる。
d="$test_dir/changed-bad"
copy_root "$d"
printf '%s\t\t\n' "$lost" >>"$d/fixture/rule-lines-changed.tsv"
expect_fail '理由のない行' lines "$d" '理由がない'
copy_root "$d.2"
printf '%s\t\t理由\n' "$lost" >>"$d.2/fixture/rule-lines-changed.tsv"
expect_fail '数が変わっていない行を載せる' lines "$d.2" '数が変わっていない行を載せている'
copy_root "$d.3"
printf '%s\t存在しない後の行\t理由\n' "$lost" >>"$d.3/fixture/rule-lines-changed.tsv"
expect_fail '後の行が見つからない' lines "$d.3" '後の行が分けたあとにない'
echo 'PASS base-size: 消えた行、数が減った行と増えた行、理由のない行、後の行のない行は、行を添えて落ちる'
