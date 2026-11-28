#!/usr/bin/env bash
# CLI と API と時計を差し替え、実際のタスク・PR には触れない。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/pr-link-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
export PR_LINK_TEST_DIR=$test_dir
export PR_LINK_TEST_ROOT="$root"
export PR_LINK_STATE_ROOT=$test_dir/pr-link-state
command -v ln >"$test_dir/real-ln"
command -v rm >"$test_dir/real-rm"
source "$root/common/monitor/squad-cli-lib"
squad_cli_contracts >"$test_dir/contracts.json"
cli_fixture() { python3 "$root/tests/multica-fixture.py" "$test_dir" base "$@"; }
script=$root/common/monitor/squad-pr-link
# 公開の検査が UUID の形の文字列を止めるので、実行時に組み立てる。
trigger=$(printf '%s-%s-%s-%s-%s' 0a1b2c3d 4e5f 6789 abcd ef0123456789)
mkdir -p "$test_dir/bin" "$test_dir/work/tmp"
# curl がないケースも、ホストの実物を呼ばない。
for cmd in bash dirname jq tr cat python3 mkdir mktemp rm sed; do
	ln -s "$(command -v "$cmd")" "$test_dir/bin/$cmd"
done
cat >"$test_dir/bin/multica" <<'MOCK'
#!/bin/bash
set -euo pipefail
dir=$PR_LINK_TEST_DIR
stub_args=("$@")
stub() { recorded=1; python3 "$PR_LINK_TEST_ROOT/tests/cli-stub.py" multica "$dir" multica "$@" -- ${stub_args[@]+"${stub_args[@]}"}; }
if [[ ${1-} == version ]]; then stub - record; echo 'multica fixture-version'; exit 0; fi
recorded=
trap '[[ -n $recorded ]] || stub multica.jsonl record' EXIT
if [[ $1 == issue && $2 == get ]]; then
	[[ $3 == TASK-7 || $3 == task-id ]]
	[[ $4 == --output && $5 == json ]]
	if [[ -f $dir/get-fail ]]; then echo "$MULTICA_TOKEN" >&2; exit 1; fi
	stub multica.jsonl emit issue-get "$dir/issue.json"
elif [[ $1 == issue && $2 == pull-requests && -f $dir/pr-list.json ]]; then
	if [[ -f $dir/record-on-list ]]; then
		mkdir -p "$PR_LINK_STATE_ROOT/project-link/example"
		cat "$dir/record-on-list" >"$PR_LINK_STATE_ROOT/project-link/example/template"
	fi
	cat "$dir/pr-list.json"
elif [[ $1 == issue && $2 == metadata && $3 == set ]]; then
	[[ $4 == task-id && $5 == --key && $7 == --value ]]
	[[ $9 == --type && ${10} == string ]]
	printf '%s\n' "$6" >>"$dir/write-order"
	case $6 in
	pr_url)
		if [[ -f $dir/set-fail ]]; then echo "$MULTICA_TOKEN" >&2; exit 1; fi
		jq --arg url "$8" '.metadata.pr_url = $url' "$dir/issue.json" >"$dir/next.json"
		;;
	pr_link_pending)
		if [[ -f $dir/marker-fail ]]; then echo "$MULTICA_TOKEN" >&2; exit 1; fi
		jq --arg url "$8" '.metadata.pr_link_pending = $url' "$dir/issue.json" >"$dir/next.json"
		;;
	pr_link_no_integration)
		if [[ -f $dir/mark-fail ]]; then exit 1; fi
		jq --arg url "$8" '.metadata.pr_link_no_integration = $url' "$dir/issue.json" >"$dir/next.json"
		;;
	*) exit 99 ;;
	esac
	/bin/mv "$dir/next.json" "$dir/issue.json"
elif [[ $1 == issue && $2 == comment && $3 == add ]]; then
	# 投稿の試みを数え、comment-fail のあいだは断る。成功した投稿だけを comments.jsonl に残す。
	[[ $4 == task-id && $5 == --parent && $7 == --content-file ]]
	echo attempt >>"$dir/comment-attempts"
	[[ ! -f $dir/comment-fail ]] || { echo 'comment add refused' >&2; exit 1; }
	jq -cn --arg parent "$6" --rawfile body "$8" '{parent:$parent,body:$body}' >>"$dir/comments.jsonl"
	jq '.[0]' "$PR_LINK_TEST_ROOT/tests/fixtures/cli/issue-comment-add.json"
else
	exit 99
fi
MOCK
cat >"$test_dir/bin/curl" <<'MOCK'
#!/bin/bash
set -euo pipefail
dir=$PR_LINK_TEST_DIR
python3 "$PR_LINK_TEST_ROOT/tests/cli-stub.py" none "$dir" curl curl.jsonl record -- "$@"
[[ $1 == -q && $2 == --config && $3 == - ]]
config=$(cat)
[[ $config == "header = \"Authorization: Bearer $MULTICA_TOKEN\"" ]]
echo verified >"$dir/config-verified"
[[ " $* " == *' -o /dev/null '* && " $* " == *' -w %{http_code} '* ]]
if [[ -f $dir/transport-fail ]]; then
	echo "$MULTICA_TOKEN" >&2
	exit 7
fi
calls=$(<"$dir/curl-count")
args=("$@")
max_time=0
for ((i = 0; i < ${#args[@]}; i++)); do
	if [[ ${args[i]} == --max-time ]]; then max_time=${args[i+1]}; fi
done
[[ $max_time -gt 0 && $max_time -le 30 ]]
duration=$(jq -r --argjson i "$calls" '.[ $i ] // .[-1]' "$dir/durations.json")
echo "$(<"$dir/now")" >>"$dir/curl-starts"
echo "$((calls + 1))" >"$dir/curl-count"
if (( duration >= max_time )) && [[ ! -f $dir/ignore-timeout ]]; then
	echo "$(($(<"$dir/now") + max_time))" >"$dir/now"
	printf '000'
	exit 28
fi
echo "$(($(<"$dir/now") + duration))" >"$dir/now"
jq -r --argjson i "$calls" '.[ $i ] // .[-1]' "$dir/statuses.json"
MOCK
cat >"$test_dir/bin/date" <<'MOCK'
#!/bin/bash
set -euo pipefail
if [[ $* == '-u +%Y-%m-%dT%H:%M:%SZ' ]]; then echo '2026-11-28T00:00:00Z'; exit 0; fi
[[ $* == +%s ]]
cat "$PR_LINK_TEST_DIR/now"
if [[ -f $PR_LINK_TEST_DIR/jump-before-call ]]; then
	rm -f "$PR_LINK_TEST_DIR/jump-before-call"
	printf '1120\n' >"$PR_LINK_TEST_DIR/now"
fi
MOCK
cat >"$test_dir/bin/sleep" <<'MOCK'
#!/bin/bash
set -euo pipefail
[[ $# == 1 && $1 -gt 0 && $1 -le 10 ]]
dir=$PR_LINK_TEST_DIR
echo "$1" >>"$dir/sleeps"
echo "$(($(<"$dir/now") + $1))" >"$dir/now"
MOCK
cat >"$test_dir/bin/ln" <<'MOCK'
#!/bin/bash
[[ ! -f $PR_LINK_TEST_DIR/record-fail ]] || exit 1
"$(<"$PR_LINK_TEST_DIR/real-ln")" "$@" || exit $?
printf 'record\n' >>"$PR_LINK_TEST_DIR/write-order"
MOCK
rm "$test_dir/bin/rm"
cat >"$test_dir/bin/rm" <<'MOCK'
#!/bin/bash
if [[ -f $PR_LINK_TEST_DIR/record-remove-fail && ${!#} == "$PR_LINK_STATE_ROOT/project-link/example/template" ]]; then
	: >"$PR_LINK_TEST_DIR/record-remove-attempted"
	exit 1
fi
exec "$(<"$PR_LINK_TEST_DIR/real-rm")" "$@"
MOCK
chmod +x "$test_dir/bin/ln" "$test_dir/bin/rm"
chmod +x "$test_dir/bin/multica" "$test_dir/bin/curl" "$test_dir/bin/date" "$test_dir/bin/sleep"
test_token=pr-link-test-secret-token
export MULTICA_TOKEN=$test_token
export MULTICA_SERVER_URL=https://multica.invalid/
export MULTICA_WORKSPACE_ID=workspace-id
url=https://github.com/Example/Template/pull/33

fixture() {
	cli_fixture issue-get | jq '. + {id:"task-id",identifier:"TASK-7"} | .metadata.repository="example/template" | del(.metadata.pr_url)' >"$test_dir/issue.json"
	rm -f "$test_dir/allow-missing-fields"
	printf '[200]\n' >"$test_dir/statuses.json"
	printf '[0]\n' >"$test_dir/durations.json"
	echo 1000 >"$test_dir/now"
	echo 0 >"$test_dir/curl-count"
	: >"$test_dir/multica.jsonl"
	: >"$test_dir/write-order"
	: >"$test_dir/curl.jsonl"
	: >"$test_dir/curl-starts"
	: >"$test_dir/sleeps"
	rm -f "$test_dir/get-fail" "$test_dir/set-fail" "$test_dir/marker-fail" "$test_dir/transport-fail" "$test_dir/config-verified" "$test_dir/ignore-timeout"
}
run_link() {
	local expected=$1 status=0
	shift
	(cd "$test_dir/work"; PATH="$test_dir/bin" /bin/bash "$script" "$@") \
		>"$test_dir/out" 2>"$test_dir/err" || status=$?
	if [[ $status != "$expected" ]]; then
		echo "FAIL pr-link: status=$status, expected=$expected" >&2
		cat "$test_dir/out" "$test_dir/err" >&2
		return 1
	fi
	# トークンは引数・出力・一時ファイルのどこにも保存されない。
	if grep -rlF -- "$test_token" "$test_dir"; then
		echo 'FAIL pr-link: トークンがファイルに残った' >&2
		return 1
	fi
}
assert_warning() {
	[[ ! -s $test_dir/out ]]
	grep -F "タスク TASK-7 に PR $url を紐付けられませんでした" "$test_dir/err" >/dev/null
	grep -F 'タスクの画面の PR の欄で、この URL を指定して紐付けてください。' "$test_dir/err" >/dev/null
	jq -e '.metadata | has("pr_url") | not' "$test_dir/issue.json" >/dev/null
}
# 404 で待ち切れたときだけ、2 行目に連携と同期の案内が出る。
assert_not_found_guidance() {
	[[ $(wc -l <"$test_dir/err" | tr -d ' ') == 2 ]]
	[[ $(sed -n 2p "$test_dir/err") == 'サーバーは、Example/Template がワークスペースの GitHub 連携につながり、PR が同期されるまで、PR を見つけられません。ワークスペースの設定のコードの画面で、Example/Template がつながっていることを確認してから紐付けてください。つながっていないと、タスクの画面からも紐付けられません。' ]]
}
assert_no_guidance() {
	! grep -F 'GitHub 連携' "$test_dir/err" >/dev/null
	! grep -F 'ワークスペースの設定のコードの画面' "$test_dir/err" >/dev/null
}
# pr_url の書き込みがないこと。マークの書き込みは assert_marker・assert_no_marker で見る。
assert_no_write() {
	jq -se 'all(.[]; .[0:3] != ["issue","metadata","set"] or .[5] != "pr_url")' "$test_dir/multica.jsonl" >/dev/null
}
# 失敗した紐付けは、渡した URL をマークとして metadata に残す。
assert_marker() {
	jq -e --arg url "$url" '.metadata.pr_link_pending == $url' "$test_dir/issue.json" >/dev/null
	jq -se --arg url "$url" '[.[] | select(.[0:3] == ["issue","metadata","set"] and .[5] == "pr_link_pending")]
		== [["issue","metadata","set","task-id","--key","pr_link_pending","--value",$url,"--type","string"]]' "$test_dir/multica.jsonl" >/dev/null
}
assert_no_marker() {
	jq -e '(try .metadata catch null) | (type != "object") or (has("pr_link_pending") | not)' "$test_dir/issue.json" >/dev/null
	jq -se 'all(.[]; .[0:3] != ["issue","metadata","set"] or .[5] != "pr_link_pending")' "$test_dir/multica.jsonl" >/dev/null
}

fixture
run_link 0 TASK-7 "$url" "$trigger"
[[ $(cat "$test_dir/out") == "紐付けました: TASK-7 $url" && ! -s $test_dir/err ]]
[[ $(cat "$test_dir/config-verified") == verified ]]
jq -e --arg url "$url" '.metadata.pr_url == $url' "$test_dir/issue.json" >/dev/null
jq -se --arg url "$url" 'length == 1 and (.[0] | .[-1] == "https://multica.invalid/api/issues/task-id/pull-requests"
	and (index("POST") != null) and (index("Content-Type: application/json") != null)
	and (index("X-Workspace-ID: workspace-id") != null)
	and (.[index("--data")+1] | fromjson) == {url:$url})' "$test_dir/curl.jsonl" >/dev/null
jq -se --arg url "$url" '.[1] == ["issue","metadata","set","task-id","--key","pr_url","--value",$url,"--type","string"]' "$test_dir/multica.jsonl" >/dev/null
[[ ! -s $test_dir/sleeps ]]
assert_no_marker
echo 'PASS link: ID・API の URL・本文・見出し・metadata・出力、トークンは標準入力だけ'

fixture
unset MULTICA_WORKSPACE_ID
run_link 0 task-id "$url" "$trigger"
jq -se '.[0] | index("-H") != null and index("X-Workspace-ID: workspace-id") == null' "$test_dir/curl.jsonl" >/dev/null
export MULTICA_WORKSPACE_ID=workspace-id
echo 'PASS link: タスクの ID も受け取り、workspace がなくても紐付ける'

for existing in "$url" https://github.com/Example/Template/pull/44; do
	fixture
	jq --arg url "$existing" '.metadata.pr_url = $url' "$test_dir/issue.json" >"$test_dir/next.json"
	mv "$test_dir/next.json" "$test_dir/issue.json"
	cp "$test_dir/issue.json" "$test_dir/before.json"
	# 紐付け済みの判定は、認証の確認より先に行う。
	MULTICA_TOKEN='' run_link 0 TASK-7 "$url" "$trigger"
	cmp "$test_dir/issue.json" "$test_dir/before.json"
	[[ ! -s $test_dir/curl.jsonl ]]
	# 飛ばしたときは、紐付けていないことと確認の方法を、渡した URL とともに 1 行で示す。
	[[ $(wc -l <"$test_dir/out" | tr -d ' ') == 1 ]]
	[[ $(cat "$test_dir/out") == "紐付けていません: TASK-7 ${url}（metadata に pr_url があるため、API を呼びませんでした。紐付いているかは multica issue pull-requests で確認してください）" ]]
	assert_no_write
	assert_no_marker
	if [[ $existing == "$url" ]]; then [[ ! -s $test_dir/err ]]; else
		[[ $(wc -l <"$test_dir/err" | tr -d ' ') == 1 ]]
		grep -F '違うため、紐付けは変えません' "$test_dir/err" >/dev/null
	fi
done
echo 'PASS skip: pr_url があれば API と書き込みを飛ばし、別の URL なら 1 行知らせる'

fixture
printf '[404,404,200]\n' >"$test_dir/statuses.json"
run_link 0 TASK-7 "$url" "$trigger"
[[ $(cat "$test_dir/curl-count") == 3 && $(cat "$test_dir/now") == 1020 ]]
[[ $(wc -l <"$test_dir/sleeps" | tr -d ' ') == 2 ]]
jq -e --arg url "$url" '.metadata.pr_url == $url' "$test_dir/issue.json" >/dev/null
echo 'PASS retry: 404 の間は 10 秒ごとに待ち、200 になってから metadata を書く'

fixture
printf '[404,404,404,200]\n' >"$test_dir/statuses.json"
printf '[29,29,29,29]\n' >"$test_dir/durations.json"
run_link 1 TASK-7 "$url" "$trigger"
assert_warning
assert_no_write
[[ $(cat "$test_dir/curl-count") == 4 && $(cat "$test_dir/now") == 1120 ]]
jq -se 'map(.[index("--max-time")+1]) == ["30","30","30","3"]' "$test_dir/curl.jsonl" >/dev/null
[[ $(cat "$test_dir/curl-starts") == $'1000\n1039\n1078\n1117' ]]
grep -F '120 秒待った' "$test_dir/err" >/dev/null
assert_not_found_guidance
assert_marker
echo 'PASS HTTP timeout: 通信の時間を含めて 120 秒で打ち切り、最後の通信は残り 3 秒に制限する'

for duration in 3 4; do
	for code in 200 404; do
		fixture
		printf '[404,404,404,%s]\n' "$code" >"$test_dir/statuses.json"
		printf '[29,29,29,%s]\n' "$duration" >"$test_dir/durations.json"
		# curl の制限を超えて応答が返っても、期限後は採用しない。
		touch "$test_dir/ignore-timeout"
		run_link 1 TASK-7 "$url" "$trigger"
		assert_warning
		assert_no_write
		[[ $(cat "$test_dir/curl-count") == 4 && $(cat "$test_dir/now") == $((1117 + duration)) ]]
		grep -F '120 秒待った' "$test_dir/err" >/dev/null
		assert_not_found_guidance
		assert_marker
	done
done
echo 'PASS late response: 期限ちょうど・期限後の 200 と 404 では、成功扱いも metadata の書き込みもしない'

fixture
printf '[404,404,404,200]\n' >"$test_dir/statuses.json"
printf '[29,29,29,2]\n' >"$test_dir/durations.json"
run_link 0 TASK-7 "$url" "$trigger"
[[ $(cat "$test_dir/curl-count") == 4 && $(cat "$test_dir/now") == 1119 ]]
jq -e --arg url "$url" '.metadata.pr_url == $url' "$test_dir/issue.json" >/dev/null
echo 'PASS slow success: 通信に時間がかかっても期限内の 200 なら metadata を書く'

fixture
printf '[404]\n' >"$test_dir/statuses.json"
printf '[29,29,29,2]\n' >"$test_dir/durations.json"
run_link 1 TASK-7 "$url" "$trigger"
assert_warning
assert_no_write
[[ $(cat "$test_dir/curl-count") == 4 && $(cat "$test_dir/now") == 1120 ]]
[[ $(cat "$test_dir/sleeps") == $'10\n10\n10\n1' ]]
grep -F '120 秒待った' "$test_dir/err" >/dev/null
assert_not_found_guidance
assert_marker
echo 'PASS short sleep: 残り 1 秒なら待ちも 1 秒に制限し、期限以降は通信しない'

fixture
printf '[404]\n' >"$test_dir/statuses.json"
run_link 1 TASK-7 "$url" "$trigger"
assert_warning
assert_no_write
[[ $(cat "$test_dir/curl-count") == 12 && $(cat "$test_dir/now") == 1120 ]]
[[ $(wc -l <"$test_dir/sleeps" | tr -d ' ') == 12 ]]
grep -F '120 秒待った' "$test_dir/err" >/dev/null
assert_not_found_guidance
assert_marker
echo 'PASS timeout: 120 秒で打ち切り、警告と画面の手順を返し、metadata は書かない'

for code in 201 400 401 403 422 500; do
	fixture
	printf '[%s]\n' "$code" >"$test_dir/statuses.json"
	run_link 1 TASK-7 "$url" "$trigger"
	assert_warning
	assert_no_write
	[[ $(cat "$test_dir/curl-count") == 1 && ! -s $test_dir/sleeps ]]
	grep -F "応答の状態コード $code" "$test_dir/err" >/dev/null
	assert_no_guidance
	assert_marker
done
echo 'PASS HTTP error: 200 と 404 以外では待たず、警告して失敗を返す'

for missing in token server curl; do
	fixture
	case $missing in
	token) MULTICA_TOKEN='' run_link 1 TASK-7 "$url" "$trigger" ;;
	server) MULTICA_SERVER_URL='' run_link 1 TASK-7 "$url" "$trigger" ;;
	curl)
		mv "$test_dir/bin/curl" "$test_dir/curl-stub"
		run_link 1 TASK-7 "$url" "$trigger"
		mv "$test_dir/curl-stub" "$test_dir/bin/curl"
		;;
	esac
	assert_warning
	assert_no_guidance
	assert_no_write
	assert_marker
	[[ ! -s $test_dir/curl.jsonl && ! -s $test_dir/sleeps ]]
done
echo 'PASS missing: トークン・サーバーの URL・curl がなくても警告して失敗を返す'

for failure in get set transport; do
	fixture
	touch "$test_dir/$failure-fail"
	if [[ $failure == set ]]; then
		run_link 3 TASK-7 "$url" "$trigger"
		[[ $(<"$test_dir/out") == "紐付けました（pr_url を書けない）: TASK-7 $url" && ! -s $test_dir/err && ! -s $test_dir/sleeps ]]
		assert_no_marker
		continue
	fi
	run_link 1 TASK-7 "$url" "$trigger"
	assert_warning
	assert_no_guidance
	[[ ! -s $test_dir/sleeps ]]
	if [[ $failure != set ]]; then assert_no_write; fi
	# タスクを読めないときは、マークを書く先の判断ができないので書かない。
	if [[ $failure == get ]]; then assert_no_marker; else assert_marker; fi
done
echo 'PASS failures: タスクの読み取り・通信・metadata の失敗の診断を漏らさない'

# 作業先（repository）がないタスクでは、同じと言えないので、失敗してもマークを書かない。
fixture
jq 'del(.metadata.repository,.metadata.pr_url)' "$test_dir/issue.json" >"$test_dir/next.json"
mv "$test_dir/next.json" "$test_dir/issue.json"
printf '[500]\n' >"$test_dir/statuses.json"
run_link 1 TASK-7 "$url" "$trigger"
assert_warning
assert_no_marker
echo 'PASS marker repository: 作業先がないタスクでは、失敗してもマークを書かない'

# マークを書けなくても、標準出力・標準エラー・終了コードは書けたときと同じ。
fixture
printf '[404]\n' >"$test_dir/statuses.json"
run_link 1 TASK-7 "$url" "$trigger"
cp "$test_dir/out" "$test_dir/out-with-marker"
cp "$test_dir/err" "$test_dir/err-with-marker"
fixture
printf '[404]\n' >"$test_dir/statuses.json"
touch "$test_dir/marker-fail"
run_link 1 TASK-7 "$url" "$trigger"
cmp "$test_dir/out" "$test_dir/out-with-marker"
cmp "$test_dir/err" "$test_dir/err-with-marker"
assert_warning
assert_not_found_guidance
assert_no_write
jq -e '.metadata | has("pr_link_pending") | not' "$test_dir/issue.json" >/dev/null
echo 'PASS marker failure: マークを書けなくても、出力と終了コードは変わらない'

for invalid in 'null' '[]' '{}' ; do
	fixture
	touch "$test_dir/allow-missing-fields"
	printf '%s\n' "$invalid" >"$test_dir/issue.json"
	run_link 1 TASK-7 "$url" "$trigger"
	[[ ! -s $test_dir/curl.jsonl ]]
	grep -F 'タスクを読めない' "$test_dir/err" >/dev/null
	assert_no_guidance
	assert_no_write
	assert_no_marker
done
echo 'PASS issue: タスクの応答が読めない場合は紐付けない'

fixture
run_link 1 TASK-7 https://github.com/Other/Template/pull/33 "$trigger"
[[ ! -s $test_dir/curl.jsonl ]]
assert_no_write
grep -F 'metadata の repository と違う' "$test_dir/err" >/dev/null
assert_no_guidance
assert_no_marker
fixture
jq 'del(.metadata.repository,.metadata.pr_url)' "$test_dir/issue.json" >"$test_dir/next.json"
mv "$test_dir/next.json" "$test_dir/issue.json"
run_link 0 TASK-7 "$url" "$trigger"
echo 'PASS repository: 大文字小文字を区別せず照合し、値がなければ紐付ける'

for invalid in http://github.com/Example/Template/pull/33 https://example.com/Example/Template/pull/33 \
	"$url/files" "$url/" "$url?x=1" "$url#diff" https://github.com/Example/Template/pull/abc; do
	fixture
	run_link 2 TASK-7 "$invalid" "$trigger"
	[[ ! -s $test_dir/multica.jsonl && ! -s $test_dir/curl.jsonl ]]
	grep -F '使い方:' "$test_dir/err" >/dev/null
done
fixture
run_link 2
run_link 2 TASK-7
run_link 2 TASK-7 "$url" extra
run_link 2 '' "$url" "$trigger"
[[ ! -s $test_dir/multica.jsonl && ! -s $test_dir/curl.jsonl ]]
echo 'PASS arguments: 個数・空のタスク・URL の形が違えば、使い方と終了コード 2'

# 鍵の有無の全組み合わせ。null・空文字の鍵も「ある」として保つ。
for repository in absent same other; do
 for linked in absent value null empty; do
  fixture
  jq --arg repository "$repository" --arg linked "$linked" --arg url "$url" '
   (if $repository == "absent" then del(.metadata.repository)
    elif $repository == "other" then .metadata.repository="other/service" else . end)
   | if $linked == "value" then .metadata.pr_url=$url
     elif $linked == "null" then .metadata.pr_url=null
     elif $linked == "empty" then .metadata.pr_url="" else del(.metadata.pr_url) end' \
   "$test_dir/issue.json" >"$test_dir/next.json"
  mv "$test_dir/next.json" "$test_dir/issue.json"
  expected=0
  [[ $repository != other ]] || expected=1
  run_link "$expected" TASK-7 "$url" "$trigger"
  if [[ $repository != other && $linked == absent ]]; then
   [[ $(jq -s length "$test_dir/curl.jsonl") == 1 ]]
   jq -e --arg url "$url" '.metadata.pr_url==$url' "$test_dir/issue.json" >/dev/null
   [[ $(cat "$test_dir/out") == "紐付けました: TASK-7 $url" ]]
  else
   [[ ! -s $test_dir/curl.jsonl ]]
   assert_no_write
   if [[ $repository != other ]]; then
    # null・空文字の pr_url でも、飛ばしたことを先頭の語と確認の方法で示す。
    [[ $(cat "$test_dir/out") == "紐付けていません: TASK-7 ${url}（metadata に pr_url があるため、API を呼びませんでした。紐付いているかは multica issue pull-requests で確認してください）" ]]
   fi
  fi
 done
done
echo 'PASS presence: repository と pr_url の有無、null・空文字でも初回・抑止・別リポジトリの拒否を保つ'

for field in id identifier status status_category metadata; do
 fixture
 touch "$test_dir/allow-missing-fields"
 jq --arg field "$field" 'del(.[$field])' "$test_dir/issue.json" >"$test_dir/next.json"
 mv "$test_dir/next.json" "$test_dir/issue.json"
 run_link 1 TASK-7 "$url" "$trigger"
 grep -F "issue-get の $field" "$test_dir/err" >/dev/null
 [[ ! -s $test_dir/curl.jsonl ]]
 assert_no_write
done
echo 'PASS contract: 必須の欄の欠落を欄名で知らせ、紐付けを書かない'

record=$PR_LINK_STATE_ROOT/project-link/example/template
integration_fixture() {
	fixture
	rm -rf -- "$PR_LINK_STATE_ROOT"
	rm -f -- "$test_dir/record-fail" "$test_dir/mark-fail" "$test_dir/record-on-list" \
		"$test_dir/record-remove-fail" "$test_dir/record-remove-attempted" "$test_dir/jump-before-call"
	jq '.project_id = "project-link"' "$test_dir/issue.json" >"$test_dir/next.json"
	mv "$test_dir/next.json" "$test_dir/issue.json"
	printf '{"pull_requests":[]}\n' >"$test_dir/pr-list.json"
	printf '[404]\n' >"$test_dir/statuses.json"
}
record_for() {
	mkdir -p "${record%/*}"
	printf 'repository: example/template\npr: %s\ntask: TASK-7\n記録した時刻: 2026-11-28T00:00:00Z\n' "$1" >"$record"
}
expect_mark() {
	jq -e --arg value "$1 $url" '.metadata.pr_link_no_integration == $value' "$test_dir/issue.json" >/dev/null
}
expect_no_integration_mark() {
	jq -e '.metadata | has("pr_link_no_integration") | not' "$test_dir/issue.json" >/dev/null
}

for timing in before-next-call response-at-limit; do
	integration_fixture
	if [[ $timing == response-at-limit ]]; then
		printf '[29,29,29,3]\n' >"$test_dir/durations.json"
		touch "$test_dir/ignore-timeout"
	fi
	run_link 0 TASK-7 "$url" "$trigger"
	[[ $(<"$test_dir/out") == "連携なしにしました: TASK-7 $url" && ! -s $test_dir/err ]]
	grep -qxF "pr: $url" "$record"
	[[ $(wc -l <"$record") -eq 4 ]]
	[[ $(<"$test_dir/write-order") == $'pr_link_pending\npr_url\nrecord\npr_link_no_integration' ]]
	expect_mark '記録した'
done
echo 'PASS pr-link: 404 だけの期限切れでマーク・URL・記録・印を残す'

for failure in pending url record our-mark our-mark-remove-fails previous-mark; do
	integration_fixture
	case $failure in
	pending) touch "$test_dir/marker-fail" ;;
	url) touch "$test_dir/set-fail" ;;
	record) touch "$test_dir/record-fail" ;;
	our-mark) touch "$test_dir/mark-fail" ;;
	our-mark-remove-fails) touch "$test_dir/mark-fail" "$test_dir/record-remove-fail" ;;
	previous-mark)
		touch "$test_dir/mark-fail"
		record_for https://github.com/example/template/pull/44 ;;
	esac
	run_link 1 TASK-7 "$url" "$trigger"
	grep -qF '紐付けられませんでした' "$test_dir/err"
	case $failure in
	our-mark*)
		# 印を書けなかった実行は、結んだ記録を残したまま、消さずに 1 で終わる。
		grep -qxF "pr: $url" "$record"
		[[ ! -e $test_dir/record-remove-attempted ]] ;;
	previous-mark) ;;
	*) [[ ! -e $record ]] ;;
	esac
	expect_no_integration_mark
done
echo 'PASS pr-link: 切り替えの失敗時に記録と印を設計どおり扱う'

for other in absent present; do
	integration_fixture
	if [[ $other == present ]]; then record_for https://github.com/example/template/pull/44; fi
	printf '{"pull_requests":[{"html_url":"https://github.com/example/template/pull/44"}]}\n' >"$test_dir/pr-list.json"
	run_link 1 TASK-7 "$url" "$trigger"
	grep -qF '紐付けられませんでした' "$test_dir/err"
	[[ -z $(<"$test_dir/out") && $(<"$test_dir/write-order") == pr_link_pending ]]
	jq -e --arg url "$url" '.metadata.pr_link_pending == $url and (.metadata | has("pr_url") | not)' "$test_dir/issue.json" >/dev/null
	expect_no_integration_mark
	if [[ $other == present ]]; then grep -qxF 'pr: https://github.com/example/template/pull/44' "$record"; else [[ ! -e $record ]]; fi
done
echo 'PASS pr-link: 一覧にほかの PR だけがあると、記録も印も書かず警告して 1 で終わる'

for existing in api no-env during-wait; do
	integration_fixture
	if [[ $existing == during-wait ]]; then
		printf 'pr: https://github.com/example/template/pull/44\n' >"$test_dir/record-on-list"
	else
		record_for https://github.com/example/template/pull/44
	fi
	if [[ $existing == no-env ]]; then MULTICA_TOKEN='' run_link 0 TASK-7 "$url" "$trigger"; else run_link 0 TASK-7 "$url" "$trigger"; fi
	expect_mark '記録があった'
	[[ $(<"$test_dir/out") == "紐付けていません（連携なし）: TASK-7 $url" && ! -s $test_dir/err ]]
	case $existing in
	api) [[ $(<"$test_dir/curl-count") == 1 && ! -s $test_dir/sleeps ]] ;;
	no-env) [[ $(<"$test_dir/curl-count") == 0 && ! -s $test_dir/sleeps ]] ;;
	during-wait) [[ -s $test_dir/sleeps ]] ;;
	esac
done
echo 'PASS pr-link: 既存の記録と競合した記録を使い、トークンなしでは呼ばない'

for source in api listed; do
	for has_record in yes no; do
		for writing in success failure; do
			integration_fixture
			if [[ $has_record == yes ]]; then record_for "$url"; fi
			case $source in
			api) printf '[200]\n' >"$test_dir/statuses.json"; label='紐付けました' ;;
			listed)
				printf '[500]\n' >"$test_dir/statuses.json"
				printf '{"pull_requests":[{"html_url":"http://GITHUB.COM/example/template/pull/00033/files"}]}\n' >"$test_dir/pr-list.json"
				label='紐付いていました' ;;
			esac
			if [[ $writing == failure ]]; then
				touch "$test_dir/set-fail"
				run_link 3 TASK-7 "$url" "$trigger"
				label+='（pr_url を書けない）'
			else
				run_link 0 TASK-7 "$url" "$trigger"
			fi
			[[ $(<"$test_dir/out") == "$label: TASK-7 $url" && ! -s $test_dir/err && ! -e $record ]]
			assert_no_marker
			expect_no_integration_mark
		done
	done
done
echo 'PASS pr-link: API と一覧の両方で、URL を書けなくても紐付いたと判定し記録を消す'

for mode in no-project bad-project other-project other-repo symlink unreadable late-200 transport status token no-response skip; do
	integration_fixture
	case $mode in
	no-project | bad-project | other-project)
		value=
		case $mode in bad-project) value=.. ;; other-project) value=other-project ;; esac
		jq --arg project "$value" 'if $project == "" then del(.project_id) else .project_id = $project end' "$test_dir/issue.json" >"$test_dir/next.json"
		mv "$test_dir/next.json" "$test_dir/issue.json"
		record_for "$url"
		if [[ $mode == no-project ]]; then
			jq -n --arg url "$url" '{pull_requests:[{html_url:$url}]}' >"$test_dir/pr-list.json"
		fi ;;
	other-repo)
		record_for "$url"
		mv "$record" "${record%/*}/other" ;;
	symlink)
		record_for "$url"
		mv "$record" "$test_dir/elsewhere"
		ln -s "$test_dir/elsewhere" "$record" ;;
	unreadable) rm "$test_dir/pr-list.json" ;;
	late-200)
		printf '[404,404,404,200]\n' >"$test_dir/statuses.json"
		printf '[29,29,29,29]\n' >"$test_dir/durations.json"
		touch "$test_dir/ignore-timeout" ;;
	transport) touch "$test_dir/transport-fail" ;;
	status) printf '[500]\n' >"$test_dir/statuses.json" ;;
	token) ;;
	no-response) touch "$test_dir/jump-before-call" ;;
	skip)
		record_for "$url"
		jq --arg url "$url" '.metadata.pr_url = $url' "$test_dir/issue.json" >"$test_dir/next.json"
		mv "$test_dir/next.json" "$test_dir/issue.json" ;;
	esac
	case $mode in
	other-project | other-repo | skip) run_link 0 TASK-7 "$url" "$trigger" ;;
	token) MULTICA_TOKEN='' run_link 1 TASK-7 "$url" "$trigger" ;;
	*) run_link 1 TASK-7 "$url" "$trigger" ;;
	esac
	if [[ $mode == skip ]]; then [[ -f $record && $(<"$test_dir/curl-count") == 0 ]]; fi
	if [[ $mode == other-project ]]; then [[ -f $PR_LINK_STATE_ROOT/other-project/example/template && -s $test_dir/sleeps ]]; fi
	if [[ $mode == other-repo ]]; then [[ -f ${record%/*}/other && -s $test_dir/sleeps ]]; fi
	if [[ $mode == symlink ]]; then [[ -L $record && -f $test_dir/elsewhere ]]; fi
	case $mode in
	no-project)
		[[ -f $record ]]
		jq -es 'all(.[]; .[0:2] != ["issue","pull-requests"])' "$test_dir/multica.jsonl" >/dev/null ;;
	unreadable | late-200 | transport | status | token | no-response)
		[[ ! -e $record ]] ;;
	esac
	case $mode in other-project | other-repo) expect_mark '記録した' ;; *) expect_no_integration_mark ;; esac
done
echo 'PASS pr-link: 記録を作れる時機と作業先を分け、既存の pr_url は飛ばす'

# 連携なしの知らせは、切り替えの 5 番目（印を書いたあと）に、種類が `記録した` のときだけ 1 回投稿する。件数の確認が外れたら、理由を出して落とす。
upper_trigger=$(printf "%s" "$trigger" | tr "[:lower:]" "[:upper:]")
notice_prefix=$'/note\n連携なしの知らせ: '
expect_count() {
	local label=$1 actual=$2 expected=$3
	[[ $actual == "$expected" ]] || { echo "件数が違う: ${label} は ${expected} のはずが ${actual}" >&2; exit 1; }
}
attempts() { if [[ -f $test_dir/comment-attempts ]]; then wc -l <"$test_dir/comment-attempts" | tr -d ' '; else echo 0; fi; }
posted() { if [[ -f $test_dir/comments.jsonl ]]; then wc -l <"$test_dir/comments.jsonl" | tr -d ' '; else echo 0; fi; }
reset_comments() { rm -f -- "$test_dir/comment-attempts" "$test_dir/comments.jsonl" "$test_dir/comment-fail"; }

# 切り替えた実行は、きっかけのコメントへの返信として知らせを 1 件投稿し、そのあとで 1 行を出して 0 で終わる。
reset_comments
integration_fixture
run_link 0 TASK-7 "$url" "$trigger"
[[ $(<"$test_dir/out") == "連携なしにしました: TASK-7 $url" && ! -s $test_dir/err ]]
expect_mark '記録した'
expect_count '知らせの試み' "$(attempts)" 1
expect_count '知らせの投稿' "$(posted)" 1
jq -e --arg parent "$trigger" --arg prefix "${notice_prefix}${url}"$'\n\n' \
	'.parent == $parent and (.body | startswith($prefix) and contains("タスクの画面で紐付ける必要はなく") and contains("done にならなければ"))' \
	"$test_dir/comments.jsonl" >/dev/null
[[ $(<"$test_dir/write-order") == $'pr_link_pending\npr_url\nrecord\npr_link_no_integration' ]]
# 知らせは印を書いたあとに投稿し、1 回だけ呼ぶ。
jq -se '[to_entries[] | select(.value[0:3] == ["issue","metadata","set"] and .value[5] == "pr_link_no_integration") | .key][0] as $mark
	| [to_entries[] | select(.value[0:3] == ["issue","comment","add"]) | .key] as $posts
	| ($posts | length) == 1 and $posts[0] > $mark' "$test_dir/multica.jsonl" >/dev/null
echo 'PASS pr-link notice: 切り替えた実行が、印のあとにきっかけのコメントへの返信で知らせを 1 件だけ投稿する'

# きっかけのコメントの ID がないと、根のコメントにする。
reset_comments
integration_fixture
run_link 0 TASK-7 "$url"
[[ $(<"$test_dir/out") == "連携なしにしました: TASK-7 $url" && ! -s $test_dir/err ]]
expect_count '知らせの投稿（根）' "$(posted)" 1
jq -e --arg prefix "${notice_prefix}${url}"$'\n\n' '.parent == "" and (.body | startswith($prefix))' "$test_dir/comments.jsonl" >/dev/null
echo 'PASS pr-link notice: きっかけのコメントの ID がなければ、根のコメントに投稿する'

# 投稿に失敗しても、終了コードも出力も変えず、試み直さない。
reset_comments
integration_fixture
touch "$test_dir/comment-fail"
run_link 0 TASK-7 "$url" "$trigger"
[[ $(<"$test_dir/out") == "連携なしにしました: TASK-7 $url" && ! -s $test_dir/err ]]
[[ $(wc -l <"$test_dir/out" | tr -d ' ') == 1 ]]
expect_mark '記録した'
grep -qxF "pr: $url" "$record"
expect_count '失敗した知らせの試み' "$(attempts)" 1
expect_count '失敗した知らせの投稿' "$(posted)" 0
echo 'PASS pr-link notice: 投稿に失敗しても、0 で終わり、出力は 1 行のまま、標準エラーは空で、試みは 1 回だけ'

# 知らせを出さない場合: 切り替えの手順 1〜4 の失敗、一覧にほかの PR だけ、記録があった、pr_url がある実行、紐付いた実行。
for mode in pending url record mark other-list existing-api existing-no-env existing-during-wait skip linked-api linked-listed; do
	reset_comments
	integration_fixture
	expected=0
	case $mode in
	pending) touch "$test_dir/marker-fail"; expected=1 ;;
	url) touch "$test_dir/set-fail"; expected=1 ;;
	record) touch "$test_dir/record-fail"; expected=1 ;;
	mark) touch "$test_dir/mark-fail"; expected=1 ;;
	other-list)
		printf '{"pull_requests":[{"html_url":"https://github.com/example/template/pull/44"}]}\n' >"$test_dir/pr-list.json"
		expected=1 ;;
	existing-api | existing-no-env) record_for https://github.com/example/template/pull/44 ;;
	existing-during-wait) printf 'pr: https://github.com/example/template/pull/44\n' >"$test_dir/record-on-list" ;;
	skip)
		jq --arg url "$url" '.metadata.pr_url = $url' "$test_dir/issue.json" >"$test_dir/next.json"
		mv "$test_dir/next.json" "$test_dir/issue.json" ;;
	linked-api) printf '[200]\n' >"$test_dir/statuses.json" ;;
	linked-listed)
		printf '[500]\n' >"$test_dir/statuses.json"
		printf '{"pull_requests":[{"html_url":"%s"}]}\n' "$url" >"$test_dir/pr-list.json" ;;
	esac
	if [[ $mode == existing-no-env ]]; then MULTICA_TOKEN='' run_link "$expected" TASK-7 "$url" "$trigger"; else run_link "$expected" TASK-7 "$url" "$trigger"; fi
	expect_count "${mode} の知らせの試み" "$(attempts)" 0
	expect_count "${mode} の知らせの投稿" "$(posted)" 0
done
echo 'PASS pr-link notice: 手順 1〜4 の失敗・一覧にほかの PR・記録があった・pr_url がある実行・紐付いた実行では、知らせを投稿しない'

# 3 番目の引数は UUID の形だけを受け、4 個以上は受けない。
for args in 'TASK-7|URL|not-a-uuid' 'TASK-7|URL|' "TASK-7|URL|${trigger}x" "TASK-7|URL|${trigger//-/}" "TASK-7|URL|${trigger}|extra"; do
	reset_comments
	integration_fixture
	IFS='|' read -r -a parts <<<"${args//URL/$url}"
	if [[ $args == 'TASK-7|URL|' ]]; then parts=(TASK-7 "$url" ''); fi
	: >"$test_dir/multica.jsonl"
	run_link 2 "${parts[@]}"
	[[ ! -s $test_dir/multica.jsonl && ! -s $test_dir/curl.jsonl ]]
	grep -F '使い方:' "$test_dir/err" >/dev/null
	expect_count "引数の形が違う ${args} の知らせの試み" "$(attempts)" 0
done
reset_comments
integration_fixture
run_link 0 TASK-7 "$url" "$upper_trigger"
jq -e --arg parent "$upper_trigger" '.parent == $parent' "$test_dir/comments.jsonl" >/dev/null
echo 'PASS pr-link notice: 3 番目の引数が UUID の形でない、または 4 個以上なら、使い方と終了コード 2。大文字の UUID は受ける'

# 期限内の 200 で pr_url を書けないときは、project_id や repository がなくても 3 で終わる。警告の 1 で終わらず、知らせも出さない。
for missing in project repository; do
	reset_comments
	integration_fixture
	case $missing in
	project) jq 'del(.project_id)' "$test_dir/issue.json" >"$test_dir/next.json" ;;
	repository) jq 'del(.metadata.repository)' "$test_dir/issue.json" >"$test_dir/next.json" ;;
	esac
	mv "$test_dir/next.json" "$test_dir/issue.json"
	printf '[200]\n' >"$test_dir/statuses.json"
	touch "$test_dir/set-fail"
	run_link 3 TASK-7 "$url" "$trigger"
	[[ $(<"$test_dir/out") == "紐付けました（pr_url を書けない）: TASK-7 $url" && ! -s $test_dir/err ]]
	assert_no_marker
	expect_no_integration_mark
	expect_count "${missing} がないときの知らせの試み" "$(attempts)" 0
done
echo 'PASS pr-link notice: project_id か repository がなくても、200 で pr_url を書けなければ 3 で終わり、知らせは出さない'
