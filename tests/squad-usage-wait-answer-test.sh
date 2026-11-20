#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-usage-wait-answer-test.sh で実行する。
# answer が人間の答えを記録の行とマークで残すこと（記録とマーク、使用率、使い方）を確認する。
# 共通の準備は tests/squad-usage-wait-test-lib.sh。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/squad-usage-wait-test-lib.sh"

reset

# ---- answer: リーダーの実行が、人間の答えを記録の行と索引のマークで残す。
# 上限に近いとき: 答えのコメントへの返信で記録を書き、タスクにマークを置く。期限は pick と同じ再開の時刻。
answer_setup near 7200
run_answer planner 待つ ans1
expect_status 0
line=$(answer_line 待つ "$answer_t" $((now + 7200)))
expect_out "$line"
[[ $(posted_count) == 1 && $(metadata_count) == 1 ]]
assert_jq --arg line "$line" '.issue == "test-issue" and .parent == "ans1" and .content == ($line + "\n")' "$test_dir/posted-comments.jsonl"
assert_jq '. == ["issue", "metadata", "set", "test-issue", "--key", "usage_answer_squad", "--value", "squad-test", "--type", "string", "--output", "json"]' "$test_dir/metadata-calls.jsonl"
# 記録の行は、人間を呼ぶ行と区別できる。
if [[ $line == 使用率の待ち:* || $line == *'24 時間を超える'* ]]; then echo '記録の行が待ちの行の形をしている' >&2; exit 1; fi
# 書いた記録が一覧に現れたあと、同じコメントで流し直しても、記録は増えない。
add_comment agent orchestrator rec1 "$now" "$line"
set_marked test-issue:DEMO-4
run_answer planner 待つ ans1
expect_none
# 進める も同じ形で書く。
answer_setup near 7200
run_answer planner 進める ans1
expect_status 0
expect_out "$(answer_line 進める "$answer_t" $((now + 7200)))"
# リセットを過ぎたのに上限に近いときは、pick と同じく 60 分後の再確認の時刻にする。
answer_setup near -100
run_answer planner 待つ ans1
expect_status 0
expect_out "$(answer_line 待つ "$answer_t" $((now + 3600)))"
# 両系統の構成で、両方が上限に近ければ早いほうの再開の時刻。片方だけなら、待たないので記録しない。
answer_setup near
set_roster "${dual[@]}"
usage 90 $((now + 7200)) 10 $((now + 100000)) 90 $((now + 3000)) true
run_answer implement 待つ ans1
expect_status 0
expect_out "$(answer_line 待つ "$answer_t" $((now + 3000)) '上限に近い枠: Claude 週 90%、Codex 週 90%')"
usage 90 $((now + 7200)) 10 $((now + 100000)) 10 $((now + 100000)) true
run_answer implement 待つ ans1
expect_none
echo 'PASS usage-wait answer: 上限に近いとき、答えのコメントへの返信に記録の行を書き、マークを置く。期限は pick と同じ再開の時刻'

# 空きが戻っていて、効いている記録もなければ、記録しない。
answer_setup free
run_answer planner 待つ ans1
expect_none
grep -qF '空きが戻っている' "$test_dir/out"
# 効いている記録があり、答えが違えば、その期限を引き継いで書く。同じ答えなら書かない。期限を過ぎた記録は効いていない。
answer_setup free
touch "$test_dir/apply-writes"
set_marked task-old:DEMO-1
add_task_comment comments-task-old.json agent orchestrator old1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 5000)))"
run_answer planner 進める ans1
expect_status 0
[[ $(<"$test_dir/out") == "使用率の答え: 進める。答えた時刻: $(iso "$answer_t")。期限: $(iso $((now + 5000)))。スクワッド: squad-test。"*'。前の答えの期限を引き継いだ' ]] || { cat "$test_dir/out" >&2; exit 1; }
# 効いている記録が取り消され（1 件）、新しい記録が書かれる（1 件）。マークは、新しい記録のタスクに置き、取り消した記録だけのタスクから外す。
[[ $(posted_count) == 2 && $(metadata_count) == 2 ]]
assert_jq -s '[.[] | .[2:4]] == [["set", "test-issue"], ["delete", "task-old"]]' "$test_dir/metadata-calls.jsonl"
set_all task-old:DEMO-1:$now test-issue:DEMO-4:$now
run_answer planner 待つ ans1
expect_none
answer_setup free
set_marked task-old:DEMO-1
add_task_comment comments-task-old.json agent orchestrator old1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now - 10)))"
run_answer planner 進める ans1
# 使う記録が期限を過ぎていても、そのタスクのマークは外さない。pick が期限を読むため。
expect_none
# 上限に近く、同じ答えが効いていれば書かない。違う答えなら、今の再開の時刻で書き直す。
answer_setup near 7200
set_marked task-old:DEMO-1
add_task_comment comments-task-old.json agent orchestrator old1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 5000)))"
run_answer planner 待つ ans1
expect_none
run_answer planner 進める ans1
expect_status 0
expect_out "$(answer_line 進める "$answer_t" $((now + 7200)))"
echo 'PASS usage-wait answer: 空きが戻っていれば、違う答えのときだけ効いている記録の期限を引き継ぐ。同じ答えと期限切れの記録では書かない'

# 答えのコメントの時刻以後の答えた時刻を持つ記録があれば、書かない。リーダー以外の作者の記録と、別のスクワッドの記録は数えない。
answer_setup near 7200
set_marked task-old:DEMO-1
add_task_comment comments-task-old.json agent orchestrator new1 $((answer_t + 10)) "$(answer_line 進める "$answer_t" $((now + 5000)))"
run_answer planner 待つ ans1
expect_none
answer_setup near 7200
set_marked task-old:DEMO-1
add_task_comment comments-task-old.json agent other-codex-fixer forged1 $((answer_t + 10)) "$(answer_line 進める $((answer_t + 10)) $((now + 5000)))"
add_task_comment comments-task-old.json agent orchestrator other-squad $((answer_t + 10)) "$(answer_line 進める $((answer_t + 10)) $((now + 5000)) | sed 's/スクワッド: squad-test/スクワッド: squad-other/')"
run_answer planner 待つ ans1
expect_status 0
expect_out "$(answer_line 待つ "$answer_t" $((now + 7200)))"
echo 'PASS usage-wait answer: 新しい答えの記録があれば書かない。リーダー以外の作者と別のスクワッドの記録は数えない'

# マークを整える。効いている記録のないタスク（記録があって、すべて期限切れか取り消し済み）のマークだけ外す。記録のないタスクと、リーダー以外の記録だけのタスクは外さない。
answer_setup near 7200
set_marked task-old:DEMO-1 task-none:DEMO-2 task-forged:DEMO-3 test-issue:DEMO-4
add_task_comment comments-task-old.json agent orchestrator old1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now - 10)))"
add_task_comment comments-task-none.json member member-test c1 $((answer_t - 1000)) 'コメント'
add_task_comment comments-task-forged.json agent other-codex-fixer forged1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 5000)))"
run_answer planner 待つ ans1
expect_status 0
[[ $(posted_count) == 1 && $(metadata_count) == 2 ]]
assert_jq -s 'map(select(.[2] == "delete")) | length == 1 and .[0] == ["issue", "metadata", "delete", "task-old", "--key", "usage_answer_squad", "--output", "json"]' "$test_dir/metadata-calls.jsonl"
# マークを外せなくても、記録は書けているので、失敗にしない。
set_marked task-old:DEMO-1 task-none:DEMO-2 task-forged:DEMO-3 test-issue:DEMO-4
touch "$test_dir/metadata-delete-fail"
run_answer planner 待つ ans1
expect_status 0
grep -qF '古いマークを外せなかった: task-old' "$test_dir/err"
[[ $(posted_count) == 1 ]]
echo 'PASS usage-wait answer: 効いている記録のないタスクのマークだけ外す。記録のないタスクのマークは外さず、外せなくても失敗にしない'

# 使用率を読めないときは、何も書かずに終了 1。
answer_setup near 7200
echo 1 >"$test_dir/usage-status"
echo 'not json' >"$test_dir/usage.json"
run_answer planner 待つ ans1
expect_status 1
grep -qF '使用率を読めないため、答えを記録していない' "$test_dir/err"
grep -qF 'もう一度返事すれば' "$test_dir/err"
expect_no_write
# 効いている記録があっても、読めなければ何も書かずに終了 1。
answer_setup near 7200
set_marked task-old:DEMO-1
add_task_comment comments-task-old.json agent orchestrator old1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 5000)))"
echo 1 >"$test_dir/usage-status"
echo 'not json' >"$test_dir/usage.json"
run_answer planner 進める ans1
expect_status 1
grep -qF '使用率を読めないため、答えを記録していない' "$test_dir/err"
expect_no_write
# 両系統の構成で、片方の系統を読めないときも同じ。
answer_setup free
set_roster "${dual[@]}"
jq '.claude = {error: "no claude"}' "$test_dir/usage.json" >"$test_dir/usage.tmp"
mv "$test_dir/usage.tmp" "$test_dir/usage.json"
run_answer implement 待つ ans1
expect_status 1
expect_no_write
# マークを置けなければ、記録も書かずに終了 1。
answer_setup near 7200
touch "$test_dir/metadata-set-fail"
run_answer planner 待つ ans1
expect_status 1
grep -qF 'マーク（usage_answer_squad）を書けない' "$test_dir/err"
[[ $(posted_count) == 0 ]]
echo 'PASS usage-wait answer: 使用率を読めないとき、マークを置けないときは、記録を書かずに終了 1'

# リーダーでない実行、タスクにない答えのコメント、メンバーでない作者のコメントは、何も書かずに終了 1。
answer_setup near 7200
answer_caller=someone-else run_answer planner 待つ ans1
expect_status 1
grep -qF 'リーダーではない' "$test_dir/err"
expect_no_write
status=0
(cd "$test_dir" && env -u MULTICA_AGENT_ID bash monitor/squad-usage-wait answer test-issue planner 待つ ans1) >"$test_dir/out" 2>"$test_dir/err" || status=$?
expect_status 1
grep -qF 'MULTICA_AGENT_ID がなく' "$test_dir/err"
run_answer planner 待つ no-such-comment
expect_status 1
grep -qF '答えのコメントがこのタスクにない' "$test_dir/err"
expect_no_write
add_comment agent orchestrator agent-answer "$answer_t" '待つ'
run_answer planner 待つ agent-answer
expect_status 1
grep -qF '作者がメンバーではない' "$test_dir/err"
expect_no_write
echo 'PASS usage-wait answer: リーダーでない実行、タスクにない答えのコメント、メンバーでない作者は、何も書かずに終了 1'

# 使い方の誤りは、CLI を呼ばずに終了 1。
answer_setup near 7200
: >"$test_dir/calls.jsonl"
for bad in '' 'planner' 'planner 待つ' 'planner 中くらい ans1' 'review 待つ ans1' 'planner 待つ ans1 余分'; do
	status=0
	# shellcheck disable=SC2086
	(cd "$test_dir" && MULTICA_AGENT_ID=orchestrator bash monitor/squad-usage-wait answer test-issue $bad) >"$test_dir/out" 2>"$test_dir/err" || status=$?
	expect_status 1
	grep -qF '使い方: squad-usage-wait' "$test_dir/err"
done
[[ ! -s $test_dir/calls.jsonl ]]
echo 'PASS usage-wait answer: 工程・判断・引数が不正なら、CLI を呼ばずに終了 1'
