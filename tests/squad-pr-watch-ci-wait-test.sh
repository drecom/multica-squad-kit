#!/usr/bin/env bash
# CLI と時計を差し替え、CI 待ちの規則・期限・解除・重複防止を確認する。
# この部分は、取り消し・混在・終わった PR・実行中の CI の待ちを確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/pr-watch-ci-wait-lib.sh"

# 取り消しは失敗ではないが、成功が確認できるまで同じ head の期限で待つ。
for age in none 0 7199 7200; do
	wait_fixture
	if [[ $age != none ]]; then old_wait "$age"; fi
	status_pr CANCELLED
	since=$(jq -r '.metadata.ci_wait_since // 10000' "$test_dir/task.json")
	if [[ $age == 7200 ]]; then
		wait_output "CI $head: 未確認（待つ上限の 2 時間を超えた）"
		assert_cleared
		[[ ! -s $test_dir/wakeups.jsonl ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
	else
		wait_output "CI $head: 未確認"
		assert_jq --argjson since "$since" '.metadata.ci_wait_since==$since and .metadata.ci_wait_rule!=null' "$test_dir/task.json"
		assert_jq -s 'length==1' "$test_dir/wakeups.jsonl"
		if [[ $age == 7199 ]]; then
			assert_jq -s '.[0].args | index("--expires-in") as $i | .[$i+1]=="1s"' "$test_dir/wakeups.jsonl"
		fi
	fi
	[[ ! -s $test_dir/posted.jsonl ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
	if [[ $age == none ]]; then
		status_pr SUCCESS
		wait_output "CI $head: 成功"
		assert_cleared
		[[ ! -s $test_dir/posted.jsonl ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
	fi
done
echo 'PASS ci-wait: 全チェックの取り消しは未確認で待ち、成功時か元の 2 時間の期限で解除する。失敗の記録は書かない'

for mixed in success external pending failure all-success; do
	wait_fixture
	old_wait
	status_pr CANCELLED
	jq --arg mixed "$mixed" --slurpfile base "$test_dir/check-prototype.json" '
		.statusCheckRollup += [if $mixed=="external" or $mixed=="all-success" then
			{__typename:"StatusContext",state:"SUCCESS",context:"external"}
		else $base[0] + {status:(if $mixed=="pending" then "IN_PROGRESS" else "COMPLETED" end),
			conclusion:(if $mixed=="pending" then null elif $mixed=="failure" then "FAILURE" else "SUCCESS" end),
			workflowName:"CI",name:"test"} end]
		| if $mixed=="all-success" then .statusCheckRollup[0].conclusion="SUCCESS" else . end' "$test_dir/pr.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/pr.json"
	case $mixed in
	success | external) expected="CI $head: 未確認" ;;
	pending) expected="CI $head: 実行中" ;;
	failure) expected=$(printf 'CI %s: 失敗あり\nCI / test' "$head") ;;
	all-success) expected="CI $head: 成功" ;;
	esac
	wait_output "$expected"
	case $mixed in
	failure | all-success) assert_cleared; [[ ! -s $test_dir/wakeups.jsonl ]] ;;
	*) assert_jq -s 'length==1' "$test_dir/wakeups.jsonl" ;;
	esac
	if [[ $mixed == failure ]]; then
		assert_jq -s 'length==1 and (.[0].body | contains("保留した失敗をリーダーが引き継ぎで受けた"))' "$test_dir/posted.jsonl"
	else [[ ! -s $test_dir/posted.jsonl ]]; fi
done
echo 'PASS ci-wait: 取り消しと成功の混在は未確認、実行中と失敗の混在は各分岐、両形式とも成功なら成功とする'

# 終了状態は CI の結果や期限より優先し、待ちの規則だけを解除する。
for ended in CLOSED MERGED done cancelled; do
	for age in none 0 7200; do
		wait_fixture
		if [[ $age != none ]]; then old_wait "$age"; fi
		case $ended in
		CLOSED | MERGED)
			jq --arg state "$ended" '.state=$state' "$test_dir/pr.json" >"$test_dir/updated.json"
			mv "$test_dir/updated.json" "$test_dir/pr.json"
			expected="CI $head: PR がマージ済みか閉じている"
			;;
		done | cancelled)
			jq --arg state "$ended" '.status=$state | .status_category=$state' "$test_dir/task.json" >"$test_dir/updated.json"
			mv "$test_dir/updated.json" "$test_dir/task.json"
			# 終了タスクは PR が読めなくても待たない。
			touch "$test_dir/fail-gh"
			expected='CI 待ち: タスクが終わっている'
			;;
		esac
		wait_output "$expected"
		assert_cleared
		if [[ $age != none ]]; then
			assert_jq 'length==2 and all(.[]; .id=="monitor-rule" or .id=="conflicts-rule")' "$test_dir/rules.json"
		fi
		assert_jq --arg ended "$ended" 'if $ended=="done" or $ended=="cancelled" then .status==$ended and .status_category==$ended else .status=="in_progress" end' "$test_dir/task.json"
		[[ ! -s $test_dir/wakeups.jsonl && ! -s $test_dir/posted.jsonl ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
		assert_jq -s 'all(.[]; .[0:3]!=["issue","metadata","set"] and .[0:2]!=["issue","status"])' "$test_dir/calls.jsonl"
	done
done
echo 'PASS ci-wait: 終了済み PR と終了・取り消し済みタスクでは、期限にかかわらず依頼も状態変更もせず待ちだけを解除する'

# 規則を作った直後に PR が終わったときも、新しい規則を残さない。
for ended in CLOSED MERGED; do
	wait_fixture
	jq --arg state "$ended" '.state=$state' "$test_dir/pr.json" >"$test_dir/pr-after-first.json"
	wait_output "CI $head: PR がマージ済みか閉じている"
	assert_cleared
	assert_jq -s 'length==1' "$test_dir/wakeups.jsonl"
	[[ ! -s $test_dir/posted.jsonl ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
done
echo 'PASS ci-wait: 規則の登録直後に PR が終了した場合も、再読で規則を解除する'

for status in SUCCESS none FAILURE; do
	wait_fixture
	old_wait
	status_pr "$status"
	case $status in SUCCESS) expected="CI $head: 成功" ;; none) expected="CI $head: チェックなし" ;; FAILURE) expected=$(printf 'CI %s: 失敗あり\nCI / test' "$head") ;; esac
	wait_output "$expected"
	assert_cleared
	assert_jq 'length==2 and all(.[]; .id=="monitor-rule" or .id=="conflicts-rule")' "$test_dir/rules.json"
	[[ ! -s $test_dir/wakeups.jsonl ]] || { echo "失敗: ${0##*/} の $LINENO 行目の確認" >&2; exit 1; }
	if [[ $status == FAILURE ]]; then
		assert_jq -s 'length==1 and .[0].body=="/note\nCI abcdef0: 保留した失敗をリーダーが引き継ぎで受けた\n"' "$test_dir/posted.jsonl"
		# 同じ失敗をもう一度受けた記録にしない。
		wait_output "$expected"
		assert_jq -s 'length==1' "$test_dir/posted.jsonl"
	else [[ ! -s $test_dir/posted.jsonl ]]; fi
done
echo 'PASS ci-wait: 成功・チェックなし・失敗を判定し、失敗を一度受け、待ちだけを解除する'

for status in running external; do
	wait_fixture
	old_wait
	[[ $status == running ]] || status_pr external
	wait_output "CI $head: 実行中" old-wait
	assert_jq -s 'length==1 and (.[0].args | index("--expires-in") as $i | .[$i+1]=="1800s")
		and (.[0].args | index("--agent-id") as $i | .[$i+1]=="orchestrator")
		and (.[0].args | index("--until-pr") as $i | .[$i+1]=="checks")
		and (.[0].args | index("--mode") as $i | .[$i+1]=="once")
		and (.[0].args | index("--on-timeout") as $i | .[$i+1]=="wake")
		and (.[0].args | index("--parent") as $i | .[$i+1]=="trigger-comment")
		and (.[0].body | contains("規則の ID"))' "$test_dir/wakeups.jsonl"
	assert_jq '.metadata.ci_wait_since==10000 and .metadata.ci_wait_head=="abcdef0123456789abcdef0123456789abcdef0123" and .metadata.ci_wait_rule!= "old-wait"' "$test_dir/task.json"
	assert_jq '[.[] | select(.id=="old-wait")] | length==0' "$test_dir/rules.json"
done
echo 'PASS ci-wait: 実行中は古い規則を消し、リーダーを最長 30 分後に 1 回起こす'
