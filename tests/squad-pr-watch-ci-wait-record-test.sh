#!/usr/bin/env bash
# CLI と時計を差し替え、CI 待ちの規則・期限・解除・重複防止を確認する。
# この部分は、制御記録の読み方・作者・規則の検査・PR の URL・引数を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/pr-watch-ci-wait-lib.sh"

# `decide` が書くマージの依頼は、制御記録（決める実行の役が書き、認める回を指し、回と決める記録より後）のときだけ依頼済みと読む。
# 回 final-1 と決める記録 decide-1 は tests/pr-watch-ci-wait-lib.sh の requested_chain が作る。
for record in agent-round agent-old-head agent-no-round agent-round-only fence fence4 fence4-tilde fence-indent4 result human other-author early unknown-round; do
	wait_fixture
	old_wait
	text=$(printf 'マージの依頼: %s\n前の回: final-1' "$head")
	author=principal type=agent at=2026-01-01T00:02:00Z
	case $record in
	agent-round) ;;
	agent-old-head) text=$(printf 'マージの依頼: 1234567\n前の回: final-1') ;;
	agent-no-round) text="マージの依頼: $head" ;;
	agent-round-only) text='前の回: final-1' ;;
	fence) text=$(printf '```\nマージの依頼: %s\n前の回: final-1\n```' "$head") ;;
	fence4) text=$(printf '````\n```\nマージの依頼: %s\n前の回: final-1\n```\n````' "$head") ;;
	fence4-tilde) text=$(printf '~~~~\n~~~\nマージの依頼: %s\n前の回: final-1\n~~~\n~~~~' "$head") ;;
	fence-indent4) text=$(printf '```\n    ```\nマージの依頼: %s\n前の回: final-1\n```' "$head") ;;
	result) text=$(printf 'マージの依頼: %s\n前の回: final-1\n返事の回: final-1' "$head") ;;
	human) type=member ;;
	other-author) author=fixer ;;
	early) at=2026-01-01T00:00:30Z ;;
	unknown-round) text=$(printf 'マージの依頼: %s\n前の回: nowhere' "$head") ;;
	esac
	requested_chain "$author" "$type" "$at" "$text"
	if [[ $record == agent-round ]]; then wait_output "CI $head: マージを依頼済み"; assert_cleared
	else
		wait_output "CI $head: 実行中"
		# 依頼済みと読まなかったので、待ちの記録（metadata）を消さず、規則も残す。
		assert_jq '.metadata.ci_wait_head == "'"$head"'" and (.metadata | has("ci_wait_since") and has("ci_wait_rule"))' "$test_dir/task.json"
	fi
done
echo 'PASS ci-wait: マージの依頼の制御記録だけを依頼済みとし、囲み（字下げ 4 個の終了風の行を含む）・結果・人間・別の作者・回より前・認めない回を指す行は読まない'

for author in orchestrator principal; do
	wait_fixture
	old_wait
	requested_chain "$author" agent 2026-01-01T00:02:00Z "$(printf '> マージの依頼: %s\n> 前の回: final-1' "$head")"
	wait_blocked '制御記録を読めない（merge-1: 引用）'
done
echo 'PASS ci-wait: マージの依頼を含む読めない候補は、依頼済みと読まず、規則と待ちの記録を残して終了 1 になる'

wait_fixture
old_wait
check_output '' ci-wait-clear test-issue
assert_cleared
check_output '' ci-wait-clear test-issue
assert_cleared
echo 'PASS ci-wait-clear: 待ちの規則と metadata を解除し、解除済みでも何も出さない'

# 読んだ pr_url を GitHub の前に検証し、不正・不一致なら待ちを消して 1 で終える。
for invalid in foreign control shape no-repository bad-repository; do
	for earlier in none old; do
		wait_fixture
		if [[ $earlier == old ]]; then old_wait; fi
		status_pr FAILURE
		case $invalid in
		foreign) filter='.metadata.pr_url="https://github.com/other/private/pull/67"' ;;
		control) filter='.metadata.pr_url="https://github.com/example/repo/pull/67\nINJECTED"' ;;
		shape) filter='.metadata.pr_url="https://example.invalid/example/repo/pull/67"' ;;
		no-repository) filter='del(.metadata.repository)' ;;
		bad-repository) filter='.metadata.repository="example/.."' ;;
		esac
		jq "$filter" "$test_dir/task.json" >"$test_dir/updated.json"
		mv "$test_dir/updated.json" "$test_dir/task.json"
		status=0
		(cd "$test_dir" && bash "$script" ci-wait test-issue orchestrator trigger-comment) >"$test_dir/output" 2>"$test_dir/error" || status=$?
		case $invalid in
		foreign | no-repository | bad-repository) expected='PR の URL が作業先と違う' ;;
		*) expected='PR の URL が不正' ;;
		esac
		[[ $status == 1 && ! -s $test_dir/output && $(<"$test_dir/error") == "$expected" ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
		[[ ! -s $test_dir/gh-calls.jsonl && ! -s $test_dir/wakeups.jsonl && ! -s $test_dir/posted.jsonl ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
		assert_cleared
		if [[ $earlier == old ]]; then
			assert_jq 'length==2 and all(.[]; .id=="monitor-rule" or .id=="conflicts-rule")' "$test_dir/rules.json"
		fi
	done
done
# 待ちを消せなくても理由を書いて 1 で終える。
wait_fixture
old_wait
jq '.metadata.pr_url="https://github.com/other/private/pull/67"' "$test_dir/task.json" >"$test_dir/updated.json"
mv "$test_dir/updated.json" "$test_dir/task.json"
printf 'issue wakeup delete' >"$test_dir/fail"
status=0
(cd "$test_dir" && bash "$script" ci-wait test-issue orchestrator trigger-comment) >"$test_dir/output" 2>"$test_dir/error" || status=$?
[[ $status == 1 && ! -s $test_dir/output && ! -s $test_dir/gh-calls.jsonl && ! -s $test_dir/wakeups.jsonl ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
grep -qxF 'PR の URL が作業先と違う' "$test_dir/error"
rm "$test_dir/fail"
echo 'PASS ci-wait: 作業先と違うか不正な pr_url では GitHub を読まず、規則を作らず待ちを消して 1 で終え、元の値もチェック名も出さない'

# クエリや /files のある URL も、規則を作る前と後の 2 回とも正規形で読む。
for suffix in '?tab=checks' '/files' '/files?x=1#y'; do
	wait_fixture
	jq --arg suffix "$suffix" '.metadata.pr_url += $suffix' "$test_dir/task.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/task.json"
	printf 'https://github.com/example/repo/pull/67' >"$test_dir/expected-pr-url"
	wait_output "CI $head: 実行中" >/dev/null
	assert_jq -s 'length==2' "$test_dir/gh-calls.jsonl"
	assert_jq -s 'all(.[]; .[0:3]==["pr","view","https://github.com/example/repo/pull/67"])' "$test_dir/gh-calls.jsonl"
	assert_jq -s 'length==1' "$test_dir/wakeups.jsonl"
done
echo 'PASS ci-wait: クエリや /files のある pr_url でも、規則の前後の 2 回とも正規形で読む'

# 紐付いていない PR でも、検証した URL で CI を読んで待つ。
wait_fixture
printf '[]' >"$test_dir/pulls.json"
wait_output "CI $head: 実行中"
assert_jq -s 'length==1 and (.[0].args | index("--on-timeout") as $i | .[$i+1]=="wake")' "$test_dir/wakeups.jsonl"
status_pr SUCCESS
wait_output "CI $head: 成功"
assert_cleared
echo 'PASS ci-wait: 紐付いていない PR でも CI を読み、実行中は --on-timeout wake の規則で待ち、成功で終える'

for operation in 'issue get test-issue' 'issue comment list' 'issue wakeup list' 'issue wakeup delete' 'issue wakeup create' 'issue metadata set' 'issue metadata delete' 'issue comment add'; do
	wait_fixture
	old_wait
	case $operation in 'issue metadata delete') status_pr SUCCESS ;; 'issue comment add') status_pr FAILURE ;; esac
	printf '%s' "$operation" >"$test_dir/fail"
	status=0
	(cd "$test_dir" && bash "$script" ci-wait test-issue orchestrator trigger-comment) >"$test_dir/output" 2>"$test_dir/error" || status=$?
	[[ $status == 1 && ! -s $test_dir/output && -s $test_dir/error ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
done
for args in 'ci-wait' 'ci-wait test-issue orchestrator' 'ci-wait test-issue orchestrator trigger rule extra' 'ci-wait-clear' 'ci-wait-clear test-issue extra'; do
	status=0
	# 使い方の検査だけ、引数を意図的に空白で分ける。
	bash "$script" $args >"$test_dir/output" 2>"$test_dir/error" || status=$?
	[[ $status == 2 && ! -s $test_dir/output && -s $test_dir/error ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
done
echo 'PASS ci-wait: 読み取り・書き込み・削除の失敗では終了コード 1、使い方の誤りでは 2 を返す'
