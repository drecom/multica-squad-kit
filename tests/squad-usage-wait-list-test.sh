#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-usage-wait-list-test.sh で実行する。
# squad-usage-wait が一覧を、作成順に 1 件重ねて読み、そろわなければ読み直し、大きな JSON を引数に渡さないことを確認する。
# 共通の準備は tests/squad-usage-wait-test-lib.sh。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/squad-usage-wait-test-lib.sh"

reset

# 絞り込みのない一覧を読んだ回数（offset ごとの読みの記録の行の合計）と、読んだ offset の並び。
list_reads() { cat "$test_dir"/list-reads-* 2>/dev/null | wc -l | tr -d ' '; }
list_offsets() { jq -sc '[.[] | select(.[0] == "issue" and .[1] == "list" and index("--limit") and (index("--metadata") | not)) | .[index("--offset") + 1]]' "$test_dir/calls.jsonl"; }

# ---- 一覧の読みは、作成順（--sort created_at --direction asc）で、100 件ずつ。続きがあるときは、1 件重ねて進める。
answer_setup near 7200
set_all task-old:DEMO-1:$now
run_answer planner 進める ans1
expect_status 0
assert_jq -s '[.[] | select(.[0] == "issue" and .[1] == "list")] | length > 0 and all(.[]; . as $c | ($c | index("--sort")) as $s | ($c | index("--direction")) as $d | $s != null and $c[$s + 1] == "created_at" and $d != null and $c[$d + 1] == "asc")' "$test_dir/calls.jsonl"
echo 'PASS usage-wait list: 一覧を、作成順（--sort created_at --direction asc）で読む'

# ---- 102 件の一覧を 1 件重ねて読む（offset 0 と 99）。重なった 1 件は 1 度だけ数え、各タスクのコメントを 1 度ずつ読む。
# 1 ページ目の JSON は 1MB を超え、記録の 1 件は 131,072 バイト以上になる。どちらも、引数に渡さずに読めること（拒まれた呼び出しの記録が空）を確認する。
answer_setup near 7200
page1=()
page2=()
for i in $(seq 1 100); do page1+=("task-$i:DEMO-$i:$now"); done
for i in $(seq 100 102); do page2+=("task-$i:DEMO-$i:$now"); done
list_total=102
set_all_page 0 true "${page1[@]}"
set_all_page 99 false "${page2[@]}"
unset list_total
head -c 12000 /dev/zero | tr '\0' a >"$test_dir/pad.txt"
jq --rawfile pad "$test_dir/pad.txt" '.issues |= map(.description = $pad)' "$test_dir/issue-list-all-0.json" >"$test_dir/pad.tmp"
mv "$test_dir/pad.tmp" "$test_dir/issue-list-all-0.json"
[[ $(wc -c <"$test_dir/issue-list-all-0.json") -gt 1048576 ]]
head -c 140000 /dev/zero | tr '\0' b >"$test_dir/bigbody.txt"
add_task_comment comments-task-50.json agent orchestrator old1 $((answer_t - 1000)) "$(answer_line 待つ $((answer_t - 1000)) $((now + 5000)))"
jq --rawfile big "$test_dir/bigbody.txt" '.[0].content += "\n" + $big' "$test_dir/comments-task-50.json" >"$test_dir/pad.tmp"
mv "$test_dir/pad.tmp" "$test_dir/comments-task-50.json"
[[ $(wc -c <"$test_dir/comments-task-50.json") -gt 131072 ]]
run_answer planner 進める ans1
expect_status 0
[[ $(list_offsets) == '["0","99","0","99"]' ]] # 最初の読みと、書いたあとの読み直し
assert_jq -s '[.[] | select(.[0] == "issue" and .[1] == "comment" and .[2] == "list" and .[3] != "test-issue") | .[3]] as $ids | ($ids | length) == 204 and ($ids | unique | length) == 102' "$test_dir/calls.jsonl"
assert_jq -s '[.[] | select(.issue != "test-issue") | .issue] == ["task-50"]' "$test_dir/posted-comments.jsonl"
assert_no_rejected_calls
echo 'PASS usage-wait list: 102 件を offset 0 と 99 で 1 件重ねて読み、重なった 1 件を 1 度だけ数える。1MB を超えるページと 131,072 バイト以上の記録も、引数に渡さずに読む'

# ---- そろわない読みは捨てて読み直し、読み直しでそろえば進む。読み直しは 2 回まで（計 3 回）。
# 3 件の一覧を 2 ページ（task-a・task-b、task-b・task-c）で読む。2 ページ目の 1 回目だけ、そろわない一覧を返す。
paged_setup() { # 続けて、2 ページ目の 1 回目のファイルを作る側が、set_all_page 1 ... で上書きする
	answer_setup near 7200
	list_total=3
	set_all_page 0 true task-a:DEMO-1:$now task-b:DEMO-2:$now
	set_all_page 1 false task-b:DEMO-2:$now task-c:DEMO-3:$now
	unset list_total
}
paged_bad() { # ファイル名の末尾（1-1 など）、has_more、total、<id>:<identifier>:<時刻> ...
	local suffix=$1 more=$2 total=$3
	shift 3
	list_total=$total
	write_all "$test_dir/issue-list-all-$suffix.json" "$more" "$@"
	unset list_total
}
# 境目の ID が合わない（2 ページ目の先頭が、前のページの最後でない）。
paged_setup
paged_bad 1-1 false 3 task-x:DEMO-9:$now task-c:DEMO-3:$now
run_answer planner 進める ans1
expect_status 0
[[ $(list_reads) == 6 ]] # 読み 2 回（ずれた回と読み直し）で各 2 ページ、書いたあとの読み直しで 2 ページ
# 同じ ID が 2 回出る。
paged_setup
paged_bad 1-1 false 3 task-b:DEMO-2:$now task-a:DEMO-1:$now
run_answer planner 進める ans1
expect_status 0
[[ $(list_reads) == 6 ]]
# total と読んだ件数が合わない。
paged_setup
paged_bad 1-1 false 4 task-b:DEMO-2:$now task-c:DEMO-3:$now
run_answer planner 進める ans1
expect_status 0
[[ $(list_reads) == 6 ]]
# 続きがあるのに、返った件数が 2 件未満。
paged_setup
list_total=3
write_all "$test_dir/issue-list-all-0-1.json" true task-a:DEMO-1:$now
unset list_total
run_answer planner 進める ans1
expect_status 0
[[ $(list_reads) == 5 ]] # ずれた回は 1 ページで止まり、読み直しと書いたあとの読み直しで各 2 ページ
echo 'PASS usage-wait list: 境目の ID・重複・total・2 件未満のずれは、捨てて読み直し、そろえば進む'

# 3 回読んでもそろわなければ、何も書かずに終了 1。理由を標準エラーに出す。
answer_setup near 7200
list_total=9
set_all task-a:DEMO-1:$now
unset list_total
run_answer planner 進める ans1
expect_status 1
expect_no_write
[[ $(list_reads) == 3 ]]
grep -qF 'タスクの一覧を 3 回読んでも、そろわなかった' "$test_dir/err"
echo 'PASS usage-wait list: 3 回読んでもそろわなければ、何も書かずに終了 1'

# pick が読むマークのある一覧も同じ。そろわなければ、待ちを置かずに終了 1。
wait_setup 100000
set_marked task-old:DEMO-1
jq '.total = 5' "$test_dir/issue-list.json" >"$test_dir/pad.tmp"
mv "$test_dir/pad.tmp" "$test_dir/issue-list.json"
run planner
expect_status 1
[[ $(wakeup_count) == 0 ]]
grep -qF 'タスクの一覧を 3 回読んでも、そろわなかった' "$test_dir/err"
assert_jq -s '[.[] | select(.[0] == "issue" and .[1] == "list" and index("--metadata"))] | length == 3' "$test_dir/calls.jsonl"
echo 'PASS usage-wait list: pick が読むマークのある一覧がそろわなければ、起こしを置かずに終了 1'
