#!/usr/bin/env bash
# マークのある PR の紐付け直しと、読み直した一覧による判定を確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/pr-watch-test-lib.sh"
pr=https://github.com/example/repo/pull/67
other=https://github.com/example/repo/pull/68
export MULTICA_TOKEN=fixture-token MULTICA_SERVER_URL=https://multica.invalid

# API のあとに一覧を更新し、読み直しの失敗も再現する。このテストだけの包みにする。
mv "$test_dir/bin/multica" "$test_dir/bin/multica-base"
cat >"$test_dir/bin/multica" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$PR_WATCH_TEST_DIR
if [[ "${1-} ${2-} ${3-}" == 'issue get test-issue' ]]; then
	# pr_link_pending は CLI の固定欄ではなく、この機能が保存する metadata の鍵。
	# それ以外の欄は実物の見本で検証し、この鍵だけを足した応答を返す。
	jq 'del(.metadata.pr_link_pending)' "$dir/task.json" >"$dir/task-base.json"
	python3 "$PR_WATCH_TEST_ROOT/tests/cli-stub.py" pr-watch "$dir" multica calls.jsonl \
		emit issue-get "$dir/task-base.json" -- "$@" >/dev/null
	cat "$dir/task.json"
	exit 0
fi
if [[ "${1-} ${2-} ${3-}" == 'issue pull-requests test-issue' && -f $dir/api-called && -f $dir/fail-after ]]; then
	exit 1
fi
exec "$dir/bin/multica-base" "$@"
EOF
cat >"$test_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$PR_WATCH_TEST_DIR
jq -cn --args '$ARGS.positional' -- "$@" >>"$dir/curl-calls.jsonl"
cat >"$dir/curl-config"
touch "$dir/api-called"
cp "$dir/pulls-after.json" "$dir/pulls.json"
[[ $(<"$dir/api-status") != transport ]] || exit 7
cat "$dir/api-status"
EOF
chmod +x "$test_dir/bin/multica" "$test_dir/bin/curl"

update_task() {
	jq "$1" "$test_dir/task.json" >"$test_dir/updated.json"
	mv "$test_dir/updated.json" "$test_dir/task.json"
}
reset_retry() {
	reset_fixture
	update_task ".metadata.pr_link_pending = \"$pr\""
	: >"$test_dir/curl-calls.jsonl"
	rm -f "$test_dir/api-called" "$test_dir/fail-after" "$test_dir/curl-config"
	printf '200' >"$test_dir/api-status"
	printf '{"pull_requests":[]}' >"$test_dir/pulls-after.json"
}
after_urls() {
	jq -n --args '{pull_requests: [$ARGS.positional[] | {html_url:.}]}' -- "$@" >"$test_dir/pulls-after.json"
}
pending_remains() { assert_jq --arg pr "$pr" '.metadata.pr_link_pending == $pr' "$test_dir/task.json"; }
pending_deleted() { assert_jq '.metadata | has("pr_link_pending") | not' "$test_dir/task.json"; }
api_once() {
	# 呼ぶ側の squad-pr-link-lib と API が読む引数、正規形の URL、30 秒の時間切れを確認する。
	assert_jq -s --arg pr "$pr" 'length == 1 and (.[0] |
		(index("--max-time") as $i | .[$i+1] == "30") and
		(index("--config") as $i | .[$i+1] == "-") and
		(index("-X") as $i | .[$i+1] == "POST") and
		(index("--data") as $i | .[$i+1] | fromjson | .url == $pr) and
		(.[-1] == "https://multica.invalid/api/issues/test-issue/pull-requests") and
		(all(.[]; contains("fixture-token") | not)))' "$test_dir/curl-calls.jsonl"
	[[ $(<"$test_dir/curl-config") == 'header = "Authorization: Bearer fixture-token"' ]]
}
no_api() { [[ ! -s $test_dir/curl-calls.jsonl ]]; }
check_retry() { check_output "$1" link-check test-issue; }

for status in 200 404 500 transport; do
	reset_retry
	printf '%s' "$status" >"$test_dir/api-status"
	after_urls "$other" 'http://GITHUB.COM/Example/Repo/pull/00067/files?split=1'
	check_retry "紐付け: 紐付いている pr: $pr"
	pending_deleted
	api_once
	assert_jq -s '[.[] | select(.[0:2] == ["issue","pull-requests"])] | length == 2' "$test_dir/calls.jsonl"
done
echo 'PASS link-retry: API の結果より読み直した一覧を優先し、紐付いたマークを消す'

for status in 200 404 403 500 transport; do
	reset_retry
	printf '%s' "$status" >"$test_dir/api-status"
	check_retry "紐付け: 紐付いていない pr: $pr"
	pending_remains
	api_once
done
echo 'PASS link-retry: 一覧が空なら 200・404・ほかの状態コード・通信の失敗でもマークを残し、待たずに 1 回だけ呼ぶ'

reset_retry
after_urls "$other"
check_retry "紐付け: 食い違い pr: $pr 紐付いた PR: $other"
pending_remains
api_once
echo 'PASS link-retry: API のあとにほかの PR だけがあると食い違いを出し、マークを残す'

for failure in cli missing-field missing-url invalid-url; do
	reset_retry
	case $failure in
	cli) touch "$test_dir/fail-after" ;;
	missing-field) printf '{}' >"$test_dir/pulls-after.json" ;;
	missing-url) printf '{"pull_requests":[{}]}' >"$test_dir/pulls-after.json" ;;
	invalid-url) after_urls https://example.invalid/pull/67 ;;
	esac
	line=$(cd "$test_dir" && bash "$script" link-check test-issue)
	[[ $line == "紐付け: 未確認 pr: $pr 理由: "* && $line != *$'\n'* ]]
	pending_remains
	api_once
done
echo 'PASS link-retry: API のあとに一覧を読めなければ未確認を 1 行で出し、マークを残す'

for missing in token server; do
	reset_retry
	if [[ $missing == token ]]; then
		(cd "$test_dir" && unset MULTICA_TOKEN && bash "$script" link-check test-issue) >"$test_dir/output"
	else
		(cd "$test_dir" && unset MULTICA_SERVER_URL && bash "$script" link-check test-issue) >"$test_dir/output"
	fi
	[[ $(<"$test_dir/output") == "紐付け: 紐付いていない pr: $pr" ]]
	pending_remains
	no_api
	assert_jq -s '[.[] | select(.[0:2] == ["issue","pull-requests"])] | length == 2' "$test_dir/calls.jsonl"
done
echo 'PASS link-retry: トークンかサーバーの URL がなくても一覧を読み直し、マークを残す'

for marker in absent other invalid number canonical; do
	reset_retry
	case $marker in
	absent) update_task 'del(.metadata.pr_link_pending)' ;;
	other) update_task ".metadata.pr_link_pending = \"$other\"" ;;
	invalid) update_task '.metadata.pr_link_pending = "https://example.invalid/pull/67"' ;;
	number) update_task '.metadata.pr_link_pending = 42' ;;
	canonical) update_task '.metadata.pr_link_pending = "http://GITHUB.COM/Example/Repo/pull/00067/files?diff=1"' ;;
	esac
	check_retry "紐付け: 紐付いていない pr: $pr"
	if [[ $marker == canonical ]]; then api_once; else no_api; fi
	assert_jq -s 'all(.[]; .[0:2] != ["issue","metadata"])' "$test_dir/calls.jsonl"
done
echo 'PASS link-retry: マークの正規形を大文字と小文字を区別せず比べ、ない・不正・別の PR なら試み直さない'

for state in foreign invalid absent mismatch unreadable; do
	reset_retry
	case $state in
	foreign) update_task '.metadata.repository = "example/other"' ;;
	invalid) update_task '.metadata.pr_url = "invalid"' ;;
	absent) update_task 'del(.metadata.pr_url)' ;;
	mismatch) after_urls "$other"; cp "$test_dir/pulls-after.json" "$test_dir/pulls.json" ;;
	unreadable) echo 'issue pull-requests test-issue' >"$test_dir/fail" ;;
	esac
	(cd "$test_dir" && bash "$script" link-check test-issue) >"$test_dir/output"
	no_api
	pending_remains
	assert_jq -s 'all(.[]; .[0:2] != ["issue","metadata"])' "$test_dir/calls.jsonl"
done
echo 'PASS link-retry: 作業先の不一致・不正・pr_url なし・食い違い・未確認ではマークを変えず試み直さない'

for deletion in success failure; do
	reset_retry
	after_urls "$pr"
	cp "$test_dir/pulls-after.json" "$test_dir/pulls.json"
	if [[ $deletion == failure ]]; then echo 'issue metadata delete' >"$test_dir/fail"; fi
	check_retry "紐付け: 紐付いている pr: $pr"
	no_api
	if [[ $deletion == success ]]; then pending_deleted; else pending_remains; fi
done
reset_retry
after_urls "$pr"
echo 'issue metadata delete' >"$test_dir/fail"
check_retry "紐付け: 紐付いている pr: $pr"
pending_remains
api_once
echo 'PASS link-retry: すでに紐付いたマークも消し、削除の失敗では出力と終了コードを変えない'

reset_retry
update_task '.status = "in_review"'
line=$(cd "$test_dir" && bash "$script" unlinked-check test-issue orchestrator)
[[ $line == /note$'\nCI abcdef0: 失敗あり\nコンフリクト: MERGEABLE head: abcdef0123456789 知らせ: なし' ]]
no_api
pending_remains
echo 'PASS link-retry: マージ待ちの見張りの判定では試み直さず、今の出力を保つ'
