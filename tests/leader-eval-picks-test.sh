#!/usr/bin/env bash
# 設計 docs/leader-eval-picks.md の判定と例外を、モデルを呼ばずに確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/leader-eval-picks.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
eval_dir="$root/tests/leader-eval"
helper=(python3 -I -B "$eval_dir/leader_eval.py" picks)
values="$eval_dir/values.json"
scenes="$test_dir/scenes"

check() {
	local expected_code=$1 expected=$2 actual_code=0
	"${helper[@]}" "$scenes" "$values" >"$test_dir/out" 2>"$test_dir/err" || actual_code=$?
	[[ $actual_code == "$expected_code" ]] || { cat "$test_dir/out" "$test_dir/err"; exit 1; }
	printf '%s\n' "$expected" >"$test_dir/expected"
	diff -u "$test_dir/expected" "$test_dir/out" || exit 1
	[[ ! -s $test_dir/err ]] || { cat "$test_dir/err"; exit 1; }
}
copy_scene() {
	rm -rf -- "$scenes"
	mkdir -p "$scenes"
	cp -R "$eval_dir/scenes/$1" "$scenes/"
}
change_cli() {
	jq "$2" "$scenes/$1/cli.json" >"$test_dir/cli.json"
	mv "$test_dir/cli.json" "$scenes/$1/cli.json"
}
missing() { printf '%s: 基準 %s: %s の pick の見本がない' "$1" "$2" "$3"; }
exception() { printf 'keep-3: pick_exceptions %s: %s' "$1" "$2"; }
synthetic() {
	rm -rf -- "$scenes"
	mkdir -p "$scenes/synthetic"
	cat >"$scenes/synthetic/scene.md" <<EOF
- 場面の ID: synthetic
- 型: 新

## 元の出来事

見本の確認。

## 入力

指定された役へ回す。

## 合格の基準

1. [記録] 指定の判定。 \`判定: $1\`
2. [採点] 設計の役へ回す。
EOF
	printf '{"commands": []}\n' >"$scenes/synthetic/cli.json"
}
add_fixture() {
	change_cli "$1" '.commands += [{"match": "squad-usage-wait pick other-task '"$2"' 小さい", "stdout": "役: fixture\n振り分け: Codex"}]'
}

scenes="$eval_dir/scenes"
check 0 'pick の見本: 143 場面を確認した'
scenes="$test_dir/scenes"
cp -R "$eval_dir/scenes" "$scenes"
change_cli add-2 '.commands |= map(select(.match != "squad-usage-wait pick issue-shop-1 designer"))'
change_cli add-4 '.commands |= map(select(.match != "squad-usage-wait pick issue-shop-1 planner"))'
check 1 "$(missing add-2 1 designer)
$(missing add-4 1 planner)"
echo 'PASS leader-eval-picks: 143 場面が通り、main の見本では add-2・add-4 だけを落とす'

copy_scene keep-26
change_cli keep-26 '.commands |= map(select(.match | startswith("squad-usage-wait pick issue-shop-1 fix") | not))'
check 1 "$(missing keep-26 1 fix)
$(missing keep-26 2 fix)"
copy_scene keep-8
change_cli keep-8 '.commands |= map(select(.match | startswith("squad-usage-wait pick issue-shop-1 principal") | not))'
check 1 "$(missing keep-8 1 principal)
$(missing keep-8 4 principal)"
copy_scene keep-27
check 0 'pick の見本: 1 場面を確認した'
change_cli keep-27 '.commands |= map(select(.match | startswith("squad-usage-wait pick issue-shop-1 fix") | not))'
check 1 "$(missing keep-27 2 fix)"
echo 'PASS leader-eval-picks: fix と後ろに語のある principal の欠けを落とし、pick の項は待ちでも足りる'

for mutation in '.exit = 3' '.stdout = "役: designer"' '.stdout = " 振り分け: Codex"'; do
	copy_scene add-2
	change_cli add-2 '(.commands[] | select(.match == "squad-usage-wait pick issue-shop-1 designer")) |= ('"$mutation"')'
	check 1 'add-2: 基準 1: designer の pick の見本に、終了コード 0 で振り分けの行のある応答がない'
done
copy_scene keep-3
change_cli keep-3 'del(.pick_exceptions)'
check 1 "$(missing keep-3 3 implement)"
copy_scene 6-1
change_cli 6-1 '.commands |= map(select(.match | startswith("squad-usage-wait pick issue-shop-1 fix") | not))'
check 1 "$(missing 6-1 2 fix)"
echo 'PASS leader-eval-picks: 選んだ応答を求め、implement の例外と正規表現の選択を読む'

for role in 'agent-(designer|planner)' 'agent-nobody' 'agent-(designer|qa)'; do
	synthetic "posted: mention://agent/$role"
	check 1 "synthetic: 基準 1: 回す先を決められない: posted: mention://agent/$role"
done
synthetic 'posted: mention://agent/agent-qa'
check 0 'pick の見本: 1 場面を確認した'
synthetic 'not-posted: mention://agent/agent-designer && not-called: squad-usage-wait pick task fix && before: read => squad-usage-wait pick task planner'
check 0 'pick の見本: 1 場面を確認した'
for term in 'called: squad-usage-wait pick task review' 'before: squad-usage-wait pick => write'; do
	synthetic "$term"
	check 1 "synthetic: 基準 1: 回す先を決められない: $term"
done
for process in planner designer implement; do
	role=$process
	[[ $process != implement ]] || role='(claude|codex)-implementer'
	synthetic "posted: [@role](mention://agent/agent-$role)"
	check 1 "$(missing synthetic 1 "$process")"
	add_fixture synthetic "$process"
	check 0 'pick の見本: 1 場面を確認した'
done
echo 'PASS leader-eval-picks: 工程が分かれる項・未知の役を落とし、対象外の役・否定・before の右側・採点を除く'

# 同じ基準で両方の項があれば選んだ応答が要り、例外は指定の組だけに効く。
synthetic 'called: squad-usage-wait pick task fix( |$) && posted: mention://agent/agent-codex-fixer && posted: mention://agent/agent-designer'
change_cli synthetic '.commands = [{"match": "squad-usage-wait pick task fix", "exit": 3}] | .pick_exceptions = [{"criterion": 1, "process": "designer", "reason": "同じ役へ返す"}]'
check 1 'synthetic: 基準 1: fix の pick の見本に、終了コード 0 で振り分けの行のある応答がない'
add_fixture synthetic fix
check 0 'pick の見本: 1 場面を確認した'
copy_scene keep-3
add_fixture keep-3 implement
check 1 "$(exception 0 '見本が足りているので例外は要らない')"
copy_scene keep-3
sed 's/posted: mention:\/\/agent\/agent-claude-implementer/called: read/' "$scenes/keep-3/scene.md" >"$test_dir/scene.md"
mv "$test_dir/scene.md" "$scenes/keep-3/scene.md"
check 1 "$(exception 0 '基準からその工程を集めないので例外は要らない')"
echo 'PASS leader-eval-picks: 例外は指定の基準と工程だけを外し、古い例外は落とす'

for mutation in '.pick_exceptions[0].reason = ""' '.pick_exceptions[0].reason = "  "' 'del(.pick_exceptions[0].reason)'; do
	copy_scene keep-3
	change_cli keep-3 "$mutation"
	check 1 "$(exception 0 'reason が空でない文字列ではない')
$(missing keep-3 3 implement)"
done
for number in 4 9 3.0 true; do
	copy_scene keep-3
	change_cli keep-3 ".pick_exceptions[0].criterion = $number"
	if [[ $number == 4 || $number == 9 ]]; then
		check 1 "$(missing keep-3 3 implement)
$(exception 0 'criterion が [記録] の基準の番号ではない')"
	else
		check 1 "$(exception 0 'criterion が [記録] の基準の番号ではない')
$(missing keep-3 3 implement)"
	fi
done
copy_scene keep-3
change_cli keep-3 '.pick_exceptions[0].process = "review"'
check 1 "$(exception 0 'process が工程ではない')
$(missing keep-3 3 implement)"
copy_scene keep-3
change_cli keep-3 '.pick_exceptions += .pick_exceptions'
check 1 "$(exception 1 'criterion と process の組が重複している')"
for mutation in '.pick_exceptions = {}' '.pick_exceptions = [null]'; do
	copy_scene keep-3
	change_cli keep-3 "$mutation"
	reason='配列ではない'
	[[ $mutation != '.pick_exceptions = [null]' ]] || reason='オブジェクトではない'
	check 1 "$(exception 0 "$reason")
$(missing keep-3 3 implement)"
done
echo 'PASS leader-eval-picks: 例外の番号・工程・理由・重複・配列と要素の形を確認する'

mkdir -p "$scenes/not-a-scene"
printf '{' >"$scenes/keep-3/cli.json"
code=0
"${helper[@]}" "$scenes" "$values" >"$test_dir/out" 2>"$test_dir/err" || code=$?
[[ $code == 2 && ! -s $test_dir/out && -s $test_dir/err ]]
for argument in "$test_dir/absent.json" ''; do
	code=0
	if [[ -n $argument ]]; then
		"${helper[@]}" "$scenes" "$argument" >"$test_dir/out" 2>"$test_dir/err" || code=$?
	else
		"${helper[@]}" >"$test_dir/out" 2>"$test_dir/err" || code=$?
	fi
	[[ $code == 2 && ! -s $test_dir/out && -s $test_dir/err ]]
done
synthetic 'called: read'
mkdir -p "$scenes/not-a-scene"
check 0 'pick の見本: 1 場面を確認した'
echo 'PASS leader-eval-picks: 読めない JSON と引数は終了 2、場面でないディレクトリは飛ばす'
