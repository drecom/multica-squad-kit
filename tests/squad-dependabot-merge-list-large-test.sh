#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-list-large-test.sh。
# この部分は、Linux の引数の上限を超える大きな値でも、list の判断が小さな値と同じになることを確認する。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。list の分類・CI・差分の読み取りを確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

source "$root/tests/dependabot-merge-test-lib.sh"

# Linux の引数の上限（131,072 バイト）を超える値でも、小さな値と同じ判断になることを確認する。
# 準備の jq は上限を超える引数を拒む包みで、拒んだ呼び出しがあれば終わるときにテストが失敗する。
# 大きな値は、jq の引数に載せず、標準入力やファイルで作る。
big_size() { (($(wc -c <"$1") >= 140000)); }

# digest だけを変える 1,000 組の行を持つ patch を作る。tag が 1 の組を 1 つだけ別のタグにすると、digest だけの更新ではなくなる。
big_digest_files() {
	local tag=${1-stable}
	jq -n --argjson n 1000 --arg tag "$tag" --arg old "$(printf '%064d' 1)" --arg new "$(printf '%064d' 2)" '[{
		filename: "Dockerfile.api", status: "modified", additions: $n, deletions: $n,
		patch: ("@@ -1 +1 @@\n" + ([range($n) | "-FROM debian:stable@sha256:\($old)\n+FROM debian:\(if . == 0 then $tag else "stable" end)@sha256:\($new)"] | join("\n")))
	}]'
}

reset_fixture
add_pr 1 dependabot/docker/debian "$(metadata '')"
big_digest_files >"$test_dir/files.json"
big_size "$test_dir/files.json"
run_list
assert_output '.[0].update_type == "patch" and .[0].ecosystem == "docker"'
big_digest_files new >"$test_dir/files.json"
run_list
assert_output '.[0].update_type == "major"'
echo 'PASS 大きな値: 1,000 組の行を持つ patch でも、digest だけの更新は patch、タグの変更は major'

# リリースノートを含む、大きなコミットのメッセージ。
reset_fixture
add_pr 1 dependabot/go_modules/api/example "$(metadata patch)"
head=$(printf '%040d' 1)
for kind in patch major; do
	{
		printf 'Bump dependency\n\n'
		head -c 140000 /dev/zero | tr '\0' a
		printf '\n'
		metadata "$kind" | tail -n +3
	} | jq -Rs '{commit: {message: ., committer: {date: "1970-01-03T07:33:20Z"}}}' >"$test_dir/$head.json"
	big_size "$test_dir/$head.json"
	run_list
	assert_output ".[0].update_type == \"$kind\""
done
echo 'PASS 大きな値: リリースノートの大きなコミットのメッセージでも、変更の種類が小さなメッセージと同じ'

# check-runs と commit status の一覧が大きい場合。読み取りは約束の欄だけに絞るので、output.text ではなく件数で大きくする。
for result in success failure pending; do
	reset_fixture
	add_pr 1 dependabot/go_modules/api/example "$(metadata patch)"
	case $result in
	success) lint=success external=success ;;
	failure) lint=failure external=success ;;
	pending) lint=success external=pending ;;
	esac
	jq -n --arg lint "$lint" '{check_runs: ([{id: 1, name: "lint", app: {id: 15368}, status: "completed", conclusion: $lint}]
		+ [range(2; 2002) | {id: ., name: "other-\(.)", app: {id: 15368}, status: "completed", conclusion: "success"}])}' >"$test_dir/checks.json"
	jq -n --arg external "$external" '[{id: 1, context: "external", state: $external}]
		+ [range(2; 3002) | {id: ., context: "other-\(.)", state: "success"}]' >"$test_dir/statuses.json"
	big_size "$test_dir/checks.json"
	big_size "$test_dir/statuses.json"
	run_list
	assert_output ".[0].ci == \"$result\""
done
echo 'PASS 大きな値: 大きな check-runs と commit status の一覧でも、CI の結果が小さな一覧と同じ'
