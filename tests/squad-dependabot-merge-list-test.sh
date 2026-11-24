#!/usr/bin/env bash
# ZIP のルートで bash tests/squad-dependabot-merge-list-test.sh。
# gh と multica を差し替え、実際の PR・タスクには書き込まない。list の分類・CI・差分の読み取りを確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

source "$root/tests/dependabot-merge-test-lib.sh"

reject_list() {
	local expected=$1 status=0
	shift
	bash "$script" example/template project-a list "$@" >"$test_dir/output" 2>"$test_dir/error" || status=$?
	[[ $status == "$expected" && ! -s $test_dir/output && -s $test_dir/error ]]
	# 引数の拒否は API の前、照合の失敗は PR の読み取りとすべての書き込みの前に止まる。
	if [[ $expected == 2 ]]; then
		jq -se 'length == 0' "$test_dir/calls.jsonl" >/dev/null
	else
		jq -se 'all(.[]; .[0] == "--version" or .[0:2] == ["api","repos/example/template"])' "$test_dir/calls.jsonl" >/dev/null
	fi
}

reset_fixture
reject_list 2
reject_list 2 --base
reject_list 2 --base main --base main
reject_list 2 --other main
reject_list 2 --base main extra
for base in '' -main 'feature+fix' 'main branch' '日本語'; do
	reject_list 2 --base "$base"
done
echo 'PASS list: --base の欠落・重複・形の違いは API を呼ばず終了 2'

reset_fixture
jq '.default_branch="develop"' "$test_dir/default-branch.json" >"$test_dir/new.json"
mv "$test_dir/new.json" "$test_dir/default-branch.json"
reject_list 1 --base main
grep -F '対象ブランチ main がデフォルトブランチ develop と一致しません' "$test_dir/error" >/dev/null
echo 'PASS list: デフォルトブランチとの不一致は両方の名前を返し、PR を読まず終了 1'

for response in '{}' '{"default_branch":null}' '{"default_branch":""}' '{"default_branch":1}' '[]' 'invalid json'; do
	reset_fixture
	printf '%s\n' "$response" >"$test_dir/gh-defect.gh-default-branch.json"
	reject_list 1 --base main
done
reset_fixture
printf 'repos/example/template --jq\n' >"$test_dir/fail"
reject_list 1 --base main
grep -F 'CLI mock failure' "$test_dir/error" >/dev/null
rm "$test_dir/fail"
echo 'PASS list: default_branch を読めないと PR の読み取りと書き込みの前に終了 1'

reset_fixture
jq '.default_branch="develop"' "$test_dir/default-branch.json" >"$test_dir/new.json"
mv "$test_dir/new.json" "$test_dir/default-branch.json"
jq '.[0].parameters.required_status_checks=[{context:"develop-check",integration_id:15368}]' "$test_dir/rules.json" >"$test_dir/target-rules.json"
jq '.check_runs[0].name="develop-check"' "$test_dir/checks.json" >"$test_dir/new.json"
mv "$test_dir/new.json" "$test_dir/checks.json"
add_pr 1 dependabot/go_modules/api/example "$(metadata patch)"
jq '.baseRefName="develop"' "$test_dir/pr-1.json" >"$test_dir/new.json"
mv "$test_dir/new.json" "$test_dir/pr-1.json"
add_pr 2 dependabot/go_modules/api/other "$(metadata minor)"
run_list develop
assert_output '[.[].base] == ["develop","main"] and all(.[]; .ci == "success")'
jq -se '[.[] | select(.[0] == "api" and (.[1] | contains("/rules/branches/"))) | .[1]] == ["repos/example/template/rules/branches/develop"]' "$test_dir/calls.jsonl" >/dev/null
echo 'PASS list: develop のルールだけで CI を判定し、main 向けの PR も base を付けて残す'

reset_fixture
jq '.default_branch="release/1.x"' "$test_dir/default-branch.json" >"$test_dir/new.json"
mv "$test_dir/new.json" "$test_dir/default-branch.json"
run_list release/1.x
assert_output '. == []'
echo 'PASS list: / と . を含むデフォルトブランチも照合できる'

reset_fixture
run_list
assert_output '. == []'
jq -se 'length == 2' "$test_dir/calls.jsonl" >/dev/null
echo 'PASS list: PR なしは空配列、ルールとチェックは取得しない'

# 分類する PR は後のページにも置く。人間・別 bot・閉じた PR は除外。
add_pr 3 dependabot/go_modules/api/example "$(metadata patch)"
add_pr 1 dependabot/npm_and_yarn/e2e/example "$(metadata major)"
add_pr 2 dependabot/github_actions/example "$(metadata minor)"
printf '[{"number":100,"state":"open","user":{"type":"User","login":"dependabot[bot]"}},{"number":101,"state":"open","user":{"type":"Bot","login":"other[bot]"}},{"number":102,"state":"closed","user":{"type":"Bot","login":"dependabot[bot]"}}]\n' >>"$test_dir/pulls.json"
# チェックと status の 2 ページ目を読む（後の成功で失敗を隠さない）。
printf '{"check_runs":[{"id":2,"name":"optional","app":{"id":15368},"status":"completed","conclusion":"failure"}]}\n' >>"$test_dir/checks.json"
printf '[{"id":2,"context":"optional","state":"failure"}]\n' >>"$test_dir/statuses.json"
run_list
assert_output '[.[].number] == [1,2,3] and [.[].update_type] == ["major","minor","patch"]
	and [.[].ecosystem] == ["npm","github-actions","gomod"]
	and all(.[]; .base == "main" and .ci == "success" and .mergeable == "MERGEABLE" and (.head_sha | length) == 40 and (.title | startswith("Bump #")))'
jq -se '[.[] | select(.[0:2] == ["pr","view"]) | .[2]] == ["1","2","3"]' "$test_dir/calls.jsonl" >/dev/null
echo 'PASS list: 全ページ・作者・状態の絞り込み、番号順、3 種類の更新、必須以外の失敗を無視'

for kind in minor major; do
	reset_fixture
	group=$(metadata patch)
	group=${group%%...*}
	group+=$(printf '\n- dependency-name: second\n  update-type: version-update:semver-%s\n...\n' "$kind")
	add_pr 1 dependabot/go_modules/api/group "$group"
	run_list
	assert_output ".[0].update_type == \"$kind\""
done
echo 'PASS list: グループは最大の更新の種類にする'

for message in "$(metadata '')" 'No metadata' "$(metadata invalid)" \
	"$(metadata patch | sed '/^\.\.\./i\
- dependency-name: missing-type\
  dependency-version: 2.0.0
')"; do
	reset_fixture
	add_pr 1 dependabot/go_modules/api/group "$message"
	run_list
	assert_output '.[0].update_type == "major"'
done
echo 'PASS list: メタデータなし・未知の種類・一部の種類が不明なら major'

reset_fixture
add_pr 1 dependabot/docker/debian "$(metadata '')"
digest_files >"$test_dir/files.json"
run_list
assert_output '.[0].update_type == "patch" and .[0].ecosystem == "docker"'
echo 'PASS list: Docker のタグ不変の digest 更新を patch にする'

for change in tag extra missing truncated; do
	case $change in
	tag) digest_files | jq '.[0].patch |= sub("\\+FROM debian:stable"; "+FROM debian:new")' ;;
	extra) digest_files | jq '. + [{filename:"other", status:"modified", additions:1, deletions:1, patch:"@@ -1 +1 @@\n-old\n+new"}]' ;;
	missing) digest_files | jq '.[0].patch = null' ;;
	truncated) digest_files | jq '.[0].additions = 2' ;;
	esac >"$test_dir/files.json"
	run_list
	assert_output '.[0].update_type == "major"'
done
echo 'PASS list: Docker のタグ変更・他の変更・差分不足は major'

digest_files | jq '.[0].filename = "compose.yaml" | .[0].patch |= gsub("FROM "; "  image: ")' >"$test_dir/files.json"
jq '.headRefName = "dependabot/docker_compose/example"' "$test_dir/pr-1.json" >"$test_dir/new.json"
mv "$test_dir/new.json" "$test_dir/pr-1.json"
run_list
assert_output '.[0].ecosystem == "docker-compose" and .[0].update_type == "patch"'
echo 'PASS list: Compose の digest 更新も確認する'

reset_fixture
add_pr 1 dependabot/go_modules/api/example "$(metadata patch)"
for state in queued in_progress; do
	jq -n --arg state "$state" '{check_runs:[{id:1,name:"lint",app:{id:15368},status:$state,conclusion:null}]}' >"$test_dir/checks.json"
	run_list
	assert_output '.[0].ci == "pending"'
done
printf '{"check_runs":[]}\n' >"$test_dir/checks.json"
run_list
assert_output '.[0].ci == "pending"'
echo 'PASS CI: 実行中・未登録の必須チェックは pending'

for conclusion in failure cancelled timed_out action_required stale neutral skipped; do
	jq -n --arg c "$conclusion" '{check_runs:[{id:1,name:"lint",app:{id:15368},status:"completed",conclusion:$c}]}' >"$test_dir/checks.json"
	printf '[{"id":1,"context":"external","state":"pending"}]\n' >"$test_dir/statuses.json"
	run_list
	assert_output '.[0].ci == "failure"'
done
echo 'PASS CI: 成功以外の終了は failure、pending より失敗を優先'

printf '{"check_runs":[{"id":1,"name":"lint","app":{"id":999},"status":"completed","conclusion":"success"}]}\n' >"$test_dir/checks.json"
printf '[{"id":1,"context":"lint","state":"success"},{"id":2,"context":"external","state":"success"}]\n' >"$test_dir/statuses.json"
run_list
assert_output '.[0].ci == "pending"'
echo 'PASS CI: 同名の別 App・commit status は指定 App の代わりにしない'

for conclusion in success failure; do
	jq -n --arg c "$conclusion" '{check_runs:[
		{id:1,name:"lint",app:{id:15368},status:"completed",conclusion:"failure"},
		{id:2,name:"lint",app:{id:15368},status:"completed",conclusion:$c}]}' >"$test_dir/checks.json"
	run_list
	assert_output ".[0].ci == \"$conclusion\""
done
printf '[{"id":1,"context":"external","state":"failure"},{"id":2,"context":"external","state":"success"}]\n' >"$test_dir/statuses.json"
jq '.check_runs[-1].conclusion = "success"' "$test_dir/checks.json" >"$test_dir/new.json"
mv "$test_dir/new.json" "$test_dir/checks.json"
run_list
assert_output '.[0].ci == "success"'
printf '[{"id":3,"context":"external","state":"error"}]\n' >>"$test_dir/statuses.json"
run_list
assert_output '.[0].ci == "failure"'
echo 'PASS CI: 再実行と commit status は最新の結果を照合し、ページをまたいだ失敗も拾う'

printf '[]\n' >"$test_dir/rules.json"
run_list
assert_output '.[0].ci == "success"'
echo 'PASS CI: 必須チェックがないルールでは必須以外を判定に使わない'

for endpoint in 'pulls?state' rules/branches commits/ /check-runs /statuses; do
	printf '%s\n' "$endpoint" >"$test_dir/fail"
	if bash "$script" example/template project-a list --base main >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
	[[ ! -s $test_dir/output ]]
	grep -q 'CLI mock failure' "$test_dir/error"
done
rm "$test_dir/fail"
echo 'PASS list: API 失敗は空配列・部分的な成功を出さずエラーを返す'

reset_fixture
add_pr 1 dependabot/go_modules/api/example "$(metadata patch)"
add_pr 2 dependabot/go_modules/api/second "$(metadata minor)"
printf 'commits/%040d\n' 2 >"$test_dir/fail"
if bash "$script" example/template project-a list --base main >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output ]]
grep -q 'CLI mock failure' "$test_dir/error"
rm "$test_dir/fail"
printf 'invalid json\n' >"$test_dir/pr-1.json"
if bash "$script" example/template project-a list --base main >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output && -s $test_dir/error ]]
echo 'PASS list: 後続 PR の取得失敗・不正な JSON でも成功した一覧を返さない'

reset_fixture
add_pr 1 dependabot/docker/debian "$(metadata '')"
digest_files >"$test_dir/files.json"
touch "$test_dir/changed-head"
if bash "$script" example/template project-a list --base main >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output ]]
grep -q 'head が変わりました' "$test_dir/error"
echo 'PASS list: Docker の差分取得中に head が変わればエラー'
rm -f "$test_dir/changed-head"

reset_fixture
bash "$script" another/service project-b list --base main >"$test_dir/output" 2>"$test_dir/error"
jq -se '. == [["api","repos/another/service","--jq","with_entries(select(.key == \"default_branch\"))"],["api","repos/another/service/pulls?state=open&per_page=100","--paginate"]]' "$test_dir/calls.jsonl" >/dev/null
[[ ! -s $test_dir/error ]]
echo 'PASS 引数のリポジトリ: 固定値ではなく、受け取った対象へ問い合わせる'

# 任意の integration_id を補うと、別 App の成功で通ってしまうので、存在を両方確認する。
for app in absent specified; do
 reset_fixture
 add_pr 1 dependabot/go_modules/api/example "$(metadata patch)"
 gh_fixture gh-branch-rules | jq --arg app "$app" '.parameters.required_status_checks[0] as $check |
  .parameters.required_status_checks=[$check + {context:"lint",integration_id:15368}] |
  if $app=="absent" then del(.parameters.required_status_checks[0].integration_id) else . end | [.]' >"$test_dir/gh-defect.gh-branch-rules.json"
 printf '{"check_runs":[{"id":1,"name":"lint","app":{"id":999},"status":"completed","conclusion":"success"}]}' >"$test_dir/checks.json"
 run_list
 if [[ $app == absent ]]; then assert_output '.[0].ci=="success"'; else assert_output '.[0].ci=="pending"'; fi
done
echo 'PASS GH optional: integration_id の省略は任意の App、指定ありはその App だけを通す'

reset_fixture
add_pr 1 dependabot/docker/example "$(metadata '')"
gh_fixture gh-pr-files | jq '[del(.patch) + {status:"modified",additions:1,deletions:1}]' >"$test_dir/gh-defect.gh-pr-files.json"
run_list
assert_output '.[0].update_type=="major"'
echo 'PASS GH optional: patch がなければ digest の更新と決めつけない'

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
