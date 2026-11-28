#!/usr/bin/env bash
# CLI と時計を差し替え、CI 待ちの規則・期限・解除・重複防止を確認する。
# この部分は、失敗・実行中・結果なしの扱いと、待ちの規則・記録の有無を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/pr-watch-ci-wait-lib.sh"

for failure in gh missing-checks no-pr; do
	wait_fixture
	old_wait
	case $failure in
	gh) touch "$test_dir/fail-gh" ;;
	missing-checks) touch "$test_dir/allow-missing-fields"; jq 'del(.statusCheckRollup)' "$test_dir/pr.json" >"$test_dir/updated.json"; mv "$test_dir/updated.json" "$test_dir/pr.json" ;;
	no-pr) jq 'del(.metadata.pr_url)' "$test_dir/task.json" >"$test_dir/updated.json"; mv "$test_dir/updated.json" "$test_dir/task.json" ;;
	esac
	wait_output "CI $head: 未確認"
	assert_jq -s 'length==1' "$test_dir/wakeups.jsonl"
	assert_jq '.metadata.ci_wait_since==10000' "$test_dir/task.json"
done
wait_fixture
touch "$test_dir/fail-gh"
wait_output 'CI: 未確認'
assert_jq '.metadata.ci_wait_head=="" and .metadata.ci_wait_since==10000' "$test_dir/task.json"
echo 17200 >"$test_dir/now"
wait_output 'CI: 未確認（待つ上限の 2 時間を超えた）'
assert_cleared
echo 'PASS ci-wait: PR・CI が読めなくても成功扱いにせず待ち、head 不明でも最初の時刻から数える'

wait_fixture
old_wait 6500
wait_output "CI $head: 実行中"
assert_jq -s '.[0].args | index("--expires-in") as $i | .[$i+1]=="700s"' "$test_dir/wakeups.jsonl"
for state in running unknown; do
	wait_fixture
	old_wait 7200
	if [[ $state == unknown ]]; then touch "$test_dir/fail-gh"; expected=未確認; else expected=実行中; fi
	wait_output "CI $head: ${expected}（待つ上限の 2 時間を超えた）"
	assert_cleared
	[[ ! -s $test_dir/wakeups.jsonl ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
done
wait_fixture
old_wait 8000
jq '.headRefOid="123456789abcdef0123456789abcdef0123456789"' "$test_dir/pr.json" >"$test_dir/updated.json"
mv "$test_dir/updated.json" "$test_dir/pr.json"
wait_output 'CI 123456789abcdef0123456789abcdef0123456789: 実行中'
assert_jq '.metadata.ci_wait_since==10000 and .metadata.ci_wait_head=="123456789abcdef0123456789abcdef0123456789"' "$test_dir/task.json"
echo 'PASS ci-wait: 残り時間で規則を短くし、同じ head は 2 時間で終え、新しい head は数え直す'

# 登録直前の完了を拾い、削除前に起動が決まった古い規則も止める。
for status in SUCCESS FAILURE none; do
	wait_fixture
	cp "$test_dir/pr.json" "$test_dir/pending.json"
	status_pr "$status"
	mv "$test_dir/pr.json" "$test_dir/pr-after-first.json"
	cp "$test_dir/pending.json" "$test_dir/pr.json"
	case $status in SUCCESS) expected="CI $head: 成功" ;; FAILURE) expected=$(printf 'CI %s: 失敗あり\nCI / test' "$head") ;; none) expected="CI $head: チェックなし" ;; esac
	wait_output "$expected"
	assert_cleared
	assert_jq -s 'length==1' "$test_dir/wakeups.jsonl"
done
wait_fixture
wait_output "CI $head: 実行中"
rule=$(jq -r '.metadata.ci_wait_rule' "$test_dir/task.json")
status_pr SUCCESS
wait_output "CI $head: 成功"
assert_cleared
: >"$test_dir/calls.jsonl"
wait_output 'CI 待ち: 終わった規則で起きた' "$rule"
assert_jq -s 'length==1 and .[0][0:3]==["issue","get","test-issue"]' "$test_dir/calls.jsonl"
wait_fixture
old_wait
wait_output 'CI 待ち: 終わった規則で起きた' stale-rule
assert_jq '.metadata.ci_wait_rule=="old-wait"' "$test_dir/task.json"
echo 'PASS ci-wait: 登録直後にも読み、別経路で終えた待ちや別の規則からの起動を重ねない'

for record in current old other-author partial; do
	wait_fixture
	old_wait
	case $record in
	current) requested orchestrator "マージの依頼: $head" ;;
	old) requested orchestrator 'マージの依頼: 1234567' ;;
	other-author) requested fixer "マージの依頼: $head" ;;
	partial) requested orchestrator "説明 マージの依頼: $head" ;;
	esac
	if [[ $record == current ]]; then wait_output "CI $head: マージを依頼済み"; assert_cleared
	else wait_output "CI $head: 実行中"; fi
done
wait_fixture
requested orchestrator "マージの依頼: $head"
wait_output "CI $head: マージを依頼済み"
assert_cleared
echo 'PASS ci-wait: 待ちの記録がなくても、リーダーの今の完全な head の行で依頼済みとする'
