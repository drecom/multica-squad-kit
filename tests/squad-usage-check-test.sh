#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-usage-check-test.sh で実行する。
# 実際の使用量の取得とタスクの作成は行わず、出力と状態の変化を CLI のモックで確認する。
set -euo pipefail
unset USAGE_CHECK_RUNTIMES
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/usage-check-test.XXXXXX")
source "$root/tests/arg-limit-lib.sh"
trap 'arg_limit_finish $? "$test_dir"' EXIT
export USAGE_FIXTURE_ROOT=$root
script=$root/common/monitor/squad-usage-check
source "$(dirname "$script")/squad-usage-lib"
awk '/^[a-z_]+\(\) \{/ {inside=1} inside {print} /^}$/ {inside=0}' "$script" >"$test_dir/functions.sh"
source "$test_dir/functions.sh"
source "$root/common/monitor/squad-cli-lib"
squad_cli_contracts >"$test_dir/contracts.json"

USAGE_CHECK_ASSIGNEE='テスト担当者 名前'
USAGE_CHECK_PROJECT=test-project
USAGE_CHECK_MEMBER=member-a
STATE_FILE=$test_dir/state.json
LABEL_NAME=運用
task_failed=false
USAGE_WARN_PERCENT=80
# ローカルのスタブだけで使う、形の合うタスク ID。
fixture_id=0
for name in ISSUE LOGIN USAGE LEGACY DISABLED OTHER; do
	fixture_id=$((fixture_id + 1))
	printf -v "TEST_${name}_ID" '%08x-%04x-%04x-%04x-%012x' 0 0 0 0 "$fixture_id"
	export "TEST_${name}_ID"
done

# 読み取りだけを偽物にし、行のキー・状態・表示を現行の出力に固定する。
mkdir -p "$test_dir/bin"
export USAGE_TEST_DIR=$test_dir
# app-server のスタブの応答待ちを短くする。時間切れを確認する長い sleep はそのまま使う。
cat >"$test_dir/bin/sleep" <<'MOCK'
#!/bin/bash
if [[ $# == 1 && $1 == 1 ]]; then
	exec /bin/sleep 0.1
fi
exec /bin/sleep "$@"
MOCK
chmod +x "$test_dir/bin/sleep"
# Linux の引数の上限を超える jq の呼び出しを拒む包み。拒んだ呼び出しは、終わるときに記録を確認する。
install_arg_limit_jq "$test_dir/bin" "$test_dir/rejected-calls"
export PATH="$test_dir/bin:$PATH"
export TZ=UTC
cat >"$test_dir/bin/claude" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
# ログインの読み取りは、バージョンと auth status --json の応答を、ファイルで差し替える。
# 出力は、メールアドレスと組織を足した偽の見本にする（実機の出力は採取しない）。
if [[ "$*" == --version ]]; then
	printf 'claude-version\n' >>"$USAGE_TEST_DIR/login-calls"
	cat "$USAGE_TEST_DIR/claude-version"
	exit "$(cat "$USAGE_TEST_DIR/claude-version.status" 2>/dev/null || echo 0)"
fi
if [[ "$*" == 'auth status --json' ]]; then
	printf 'claude-auth\n' >>"$USAGE_TEST_DIR/login-calls"
	[[ ! -f $USAGE_TEST_DIR/claude-auth-hang ]] || exec sleep 600
	cat "$USAGE_TEST_DIR/claude-auth.json"
	echo 'ログインの警告 fake.person@example.invalid' >&2
	exit "$(cat "$USAGE_TEST_DIR/claude-auth.status")"
fi
[[ "$*" == '-p /usage --output-format json' ]]
python3 "$USAGE_FIXTURE_ROOT/tests/cli-stub.py" usage "$USAGE_TEST_DIR" claude - emit claude-usage "$USAGE_TEST_DIR/claude.json" -- "$@"
printf 'claude\n' >>"$USAGE_TEST_DIR/runtime-calls"
cat "$USAGE_TEST_DIR/claude.err" >&2
exit "$(cat "$USAGE_TEST_DIR/claude.status")"
MOCK
cat >"$test_dir/bin/codex" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == --version ]]; then
	jq -r '.versions.codex' "$USAGE_FIXTURE_ROOT/tests/fixtures/cli/USAGE-CAPTURE.json"
	exit 0
fi
if [[ "$*" == 'login status' ]]; then
	printf 'codex-login\n' >>"$USAGE_TEST_DIR/login-calls"
	cat "$USAGE_TEST_DIR/codex-login.err" >&2
	[[ ! -f $USAGE_TEST_DIR/codex-login-hang ]] || exec sleep 600
	exit "$(cat "$USAGE_TEST_DIR/codex-login.status")"
fi
[[ "$*" == app-server ]]
stub_args=("$@")
stub() { recorded=1; python3 "$USAGE_FIXTURE_ROOT/tests/cli-stub.py" usage "$USAGE_TEST_DIR" codex - "$@" -- ${stub_args[@]+"${stub_args[@]}"}; }
recorded=
trap '[[ -n $recorded ]] || stub record' EXIT
printf 'codex\n' >>"$USAGE_TEST_DIR/runtime-calls"
for _ in 1 2 3; do
	IFS= read -r request
	printf '%s\n' "$request" >>"$USAGE_TEST_DIR/requests.jsonl"
done
if [[ -f "$USAGE_TEST_DIR/codex-defect.json" ]]; then
	jq -cn --slurpfile result "$USAGE_TEST_DIR/codex-defect.json" '{id:2,result:$result[0]}'
else
	stub emit codex-rate-limits "$USAGE_TEST_DIR/codex.jsonl"
fi
cat >/dev/null
MOCK
chmod +x "$test_dir/bin/claude" "$test_dir/bin/codex"
: >"$test_dir/claude.err"
echo 0 >"$test_dir/claude.status"
echo '2.1.322 (Claude Code)' >"$test_dir/claude-version"
echo 0 >"$test_dir/claude-auth.status"
# 既定は、期限のない ok。ログインのテストが、欄を差し替える。
claude_auth() { # 終了コード JSON
	echo "$1" >"$test_dir/claude-auth.status"
	printf '%s\n' "$2" >"$test_dir/claude-auth.json"
}
claude_auth 0 '{"loggedIn":true,"authMethod":"claude.ai","email":"fake.person@example.invalid","orgName":"Fake Org Inc"}'
codex_login() { # 終了コード stderr
	echo "$1" >"$test_dir/codex-login.status"
	printf '%s\n' "$2" >"$test_dir/codex-login.err"
}
codex_login 0 'Logged in using ChatGPT'

assert_fetch() {
	"fetch_$1" >"$test_dir/actual" 2>"$test_dir/err"
	diff -u "$test_dir/expected" "$test_dir/actual"
	test ! -s "$test_dir/err"
}

assert_fetch_error() {
	if "fetch_$1" >"$test_dir/actual" 2>"$test_dir/err"; then
		echo "FAIL $1: 読み取りが失敗していない" >&2
		exit 1
	fi
	test ! -s "$test_dir/actual"
	diff -u "$test_dir/expected" "$test_dir/err"
}

jq -cn --arg result '使用量:
Current session: 79% used · resets Oct 27 at 12:29pm (Asia/Tokyo)
Current week (all models): 80% used · resets Oct 31 at 4:59am (Asia/Tokyo)
Current week (Fable): 100% used · resets Oct 31 at 5am (Asia/Tokyo)' \
	'{is_error: false, result: $result}' >"$test_dir/claude.json"
cat >"$test_dir/expected" <<'EXPECTED'
claude:Current session	ok	Claude の Current session	79%（Oct 27 at 12:29pm (Asia/Tokyo) にリセット）
claude:Current week (all models)	warn	Claude の Current week (all models)	80%（Oct 31 at 4:59am (Asia/Tokyo) にリセット）
claude:Current week (Fable)	limited	Claude の Current week (Fable)	100%（Oct 31 at 5am (Asia/Tokyo) にリセット）
EXPECTED
echo '設定の警告' >"$test_dir/claude.err"
assert_fetch claude
echo 'PASS Claude: 枠のキー・表示と 79/80/100% の判定、stderr の分離'

echo 1 >"$test_dir/claude.status"
echo '失敗' >"$test_dir/claude.json"
echo 'claude -p /usage が失敗した: 失敗 設定の警告' >"$test_dir/expected"
assert_fetch_error claude
echo 0 >"$test_dir/claude.status"
: >"$test_dir/claude.err"
echo '{"is_error":true,"result":"ログインが必要"}' >"$test_dir/claude.json"
echo 'claude -p /usage がエラーを返した: ログインが必要' >"$test_dir/expected"
assert_fetch_error claude
echo '{"is_error":false,"result":"使用率の表示がない"}' >"$test_dir/claude.json"
echo '/usage の表示から使用率を読めなかった: 使用率の表示がない' >"$test_dir/expected"
assert_fetch_error claude
echo 'PASS Claude: コマンド失敗・エラー応答・使用率なしの理由と終了コード'

cat >"$test_dir/codex.jsonl" <<'MOCK'
{"id":1,"result":{}}
{"method":"account/rateLimits/updated","params":{}}
{"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{"codex":{"primary":{"windowDurationMins":10080,"usedPercent":80.9,"resetsAt":604800},"secondary":{"windowDurationMins":300,"usedPercent":79.9,"resetsAt":0}},"extra":{"primary":{"windowDurationMins":60,"usedPercent":100,"resetsAt":0},"secondary":null}}}}
MOCK
cat >"$test_dir/expected" <<'EXPECTED'
codex:codex:10080	warn	Codex の codex の週の枠	80%（01/08 00:00 にリセット）
codex:codex:300	ok	Codex の codex の5 時間の枠	79%（01/01 00:00 にリセット）
codex:extra:60	limited	Codex の extra の60 分の枠	100%（01/01 00:00 にリセット）
codex:allowed	ok	Codex を使えるか	使える
EXPECTED
assert_fetch codex
jq -se 'length == 3 and .[0].method == "initialize"
	and .[0].params.clientInfo == {name: "squad-usage-check", version: "1.0.0"}
	and .[1].method == "initialized"
	and .[2] == {jsonrpc: "2.0", id: 2, method: "account/rateLimits/read"}' \
	"$test_dir/requests.jsonl" >/dev/null
echo 'PASS Codex: 枠のキー・表示・切り捨て・null 枠と問い合わせ'

for reason in credit_limit unknown; do
	jq -cn --arg reason "$reason" '{id: 2, result: {ordinaryUsageAllowed: false,
		rateLimitsByLimitId: {}, rateLimits: (if $reason == "unknown" then {} else {rateLimitReachedType: $reason} end)}}' \
		>"$test_dir/codex.jsonl"
	if [[ "$reason" == unknown ]]; then reason='理由は不明'; fi
	printf 'codex:allowed\tlimited\tCodex を使えるか\t使えない（%s）\n' "$reason" >"$test_dir/expected"
	assert_fetch codex
done
echo 'PASS Codex: 利用不可の理由と理由なしの表示'

echo '{"id":2,"error":{"message":"ログインが必要"}}' >"$test_dir/codex.jsonl"
echo 'codex app-server がエラーを返した: ログインが必要' >"$test_dir/expected"
assert_fetch_error codex
# 応答なしの 30 回の待機は、テストでは待たない。
(
	sleep() { :; }
	: >"$test_dir/codex.jsonl"
	echo 'codex app-server から使用量の応答がなかった' >"$test_dir/expected"
	assert_fetch_error codex
)
echo 'PASS Codex: エラー応答・応答なしの理由と終了コード'

create_default=$(python3 "$root/tests/multica-fixture.py" "$test_dir" base issue-create | jq '.id = env.TEST_ISSUE_ID')
label_default=$(python3 "$root/tests/multica-fixture.py" "$test_dir" base label-list | jq '[.id = "operations-label" | .name = "運用"]')
get_default=$(python3 "$root/tests/multica-fixture.py" "$test_dir" base issue-get)
export create_default label_default get_default
# 見張りがタスクを更新する前に読むサーバーのタスク。既定は、この見張りが同じプロジェクトに、指定の題で作ったもの。
# get-title に題を、get-override.json に差し替える欄を置く。
export MULTICA_AGENT_ID=test-agent
record_mock_task() {
	[[ -f $test_dir/check-pairs ]] || return 0
	jq -c --argjson call "$(wc -l <"$test_dir/calls.jsonl")" --arg kind "$1" --arg title "${2-}" '
		{call: $call, kind: $kind, task: (if $kind == "create" then . + {title: $title} else . end)}' \
		>>"$test_dir/responses.jsonl"
}
export -f record_mock_task
multica() {
	if [[ "$*" == version ]]; then echo 'multica fixture-version'; return; fi
	python3 "$USAGE_FIXTURE_ROOT/tests/cli-stub.py" none "$test_dir" multica calls.jsonl record -- "$@"
	case "$1 $2" in
	'issue create')
		if [[ -f $test_dir/fail-create-prefix && $4 == "$(cat "$test_dir/fail-create-prefix")"* ]]; then
			echo 'mock create failure' >&2
			return 1
		fi
		local file response title=$4
		while (($#)); do
			if [[ $1 == --description-file ]]; then file=$2; break; fi
			shift
		done
		cat "$file" >"$test_dir/description.md"
		if [[ -f $test_dir/create-response.json ]]; then
			response=$(cat "$test_dir/create-response.json")
		else
			response=$create_default
		fi
		record_mock_task create "$title" <<<"$response" || return 1
		echo "$response"
		;;
	'issue comment')
		if [[ -f $test_dir/fail-comment ]]; then echo 'mock comment failure' >&2; return 1; fi
		local file
		while (($#)); do
			if [[ $1 == --content-file ]]; then file=$2; break; fi
			shift
		done
		jq -Rs '{body:.}' <"$file" >>"$test_dir/comments.jsonl"
		;;
	'issue get')
		if [[ -f $test_dir/fail-get ]]; then echo 'mock get failure' >&2; return 1; fi
		if [[ -f $test_dir/hang-get ]]; then exec sleep 600; fi
		local response
		response=$(jq --arg id "$3" --arg project "$USAGE_CHECK_PROJECT" --arg agent "${MULTICA_AGENT_ID-}" --arg title "$(cat "$test_dir/get-title")" \
			'.id = $id | .project_id = $project | .creator_type = "agent" | .creator_id = $agent | .title = $title' <<<"$get_default" |
			jq --slurpfile o <(if [[ -f $test_dir/get-override.json ]]; then cat "$test_dir/get-override.json"; else echo '{}'; fi) '. + $o[0]') || return 1
		record_mock_task get <<<"$response" || return 1
		echo "$response"
		;;
	'issue update')
		if [[ -f $test_dir/fail-update ]]; then echo 'mock update failure' >&2; return 1; fi
		local issue=$3 title file
		while (($#)); do
			case $1 in
			--title) title=$2 ;;
			--description-file) file=$2 ;;
			esac
			shift
		done
		jq -n --arg id "$issue" --arg t "$title" --rawfile d "$file" '{id: $id, title: $t, description: $d}' >>"$test_dir/updates.jsonl"
		;;
	'issue status') [[ $4 == done && ! -f $test_dir/fail-done ]] ;;
	'label list')
		[[ ! -f $test_dir/fail-label-list ]] || return 1
		if [[ -f $test_dir/label-response.json ]]; then cat "$test_dir/label-response.json"; else
			echo "$label_default"
		fi ;;
	'issue label')
		if [[ -f $test_dir/check-saved-id ]]; then
			jq -e --arg id "$4" '."login:claude".issue == $id' \
				"$USAGE_CHECK_STATE_ROOT/$USAGE_CHECK_PROJECT/$USAGE_CHECK_MEMBER.state" >/dev/null || return 1
			touch "$test_dir/saved-id-checked"
		fi
		[[ $3 == add && $5 == operations-label && ! -f $test_dir/fail-label ]] ;;
	*) echo "Unexpected mock call: $*" >&2; return 1 ;;
	esac
}

# 読み取りの時間切れは Python から CLI を起動するので、同じモックを実行ファイルとしても置く。
export test_dir USAGE_CHECK_PROJECT
{
	printf '#!/usr/bin/env bash\n'
	declare -f record_mock_task multica
	printf 'multica "$@"\n'
} >"$test_dir/bin/multica"
chmod +x "$test_dir/bin/multica"

# 警告・使用上限到達・取得エラーのどの場合も、作成時点でプロジェクトを渡す。
for level in warn limited error; do
	state='{}'
	: >"$test_dir/calls.jsonl"
	apply claude:test-key "$level" 'テスト枠' '詳細'
	jq -se --arg project "$USAGE_CHECK_PROJECT" --arg assignee "$USAGE_CHECK_ASSIGNEE" '
		def value($flag): . as $args | index($flag) as $i | $args[$i + 1];
		[.[] | select(.[0:2] == ["issue", "create"])] as $creates
		| ($creates | length) == 1
		and ($creates[0] | value("--project") == $project and value("--assignee") == $assignee)
		and ([.[] | select(.[0:3] == ["issue", "label", "add"])] | length) == 1
	' "$test_dir/calls.jsonl" >/dev/null
	jq -e --arg level "$level" '."claude:test-key" == {level: $level, issue: env.TEST_ISSUE_ID, labeled: true}' "$STATE_FILE" >/dev/null
	echo "PASS $level: タスクの作成時にプロジェクトと担当を渡し、状態を保存"
done

# 本体も別の作業ディレクトリから動かし、80% の警告と保存済みのキーを確認する。
echo '{"is_error":false,"result":"Current session: 80% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
echo '{"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{"codex":{"primary":{"windowDurationMins":10080,"usedPercent":80,"resetsAt":604800},"secondary":null}}}}' >"$test_dir/codex.jsonl"
: >"$test_dir/calls.jsonl"
(
	export -f multica
	export test_dir USAGE_CHECK_ASSIGNEE USAGE_CHECK_PROJECT USAGE_CHECK_MEMBER
	export USAGE_CHECK_STATE_ROOT="$test_dir/states"
	state_file=$(usage_check_state_path)
	export USAGE_WARN_PERCENT
	cd "$test_dir"
	bash "$script"
	jq -e '. == {"claude:Current session": {level: "warn", issue: env.TEST_ISSUE_ID, labeled: true},
		"codex:codex:10080": {level: "warn", issue: env.TEST_ISSUE_ID, labeled: true},
		"login:claude": {level: "ok"},
		"login:codex": {level: "ok"}}' "$state_file" >/dev/null
	jq -se '[.[] | select(.[0:2] == ["issue", "create"])] | length == 2' "$test_dir/calls.jsonl" >/dev/null
	: >"$test_dir/calls.jsonl"
	USAGE_CHECK_RUNTIMES='claude codex' bash "$script"
	test ! -s "$test_dir/calls.jsonl"
)
# 同じ root でもプロジェクトかメンバーが違えば、それぞれ初回の通知を作る。
(
	export -f multica
	export test_dir USAGE_CHECK_ASSIGNEE USAGE_CHECK_PROJECT USAGE_CHECK_MEMBER
	export USAGE_CHECK_STATE_ROOT="$test_dir/states"
	export USAGE_WARN_PERCENT
	for pair in test-project:member-b other-project:member-a; do
		export USAGE_CHECK_PROJECT=${pair%:*} USAGE_CHECK_MEMBER=${pair#*:}
		: >"$test_dir/calls.jsonl"
		(cd "$test_dir" && bash "$script")
		jq -se '[.[] | select(.[0:2] == ["issue", "create"])] | length == 2' "$test_dir/calls.jsonl" >/dev/null
		[[ -s $(usage_check_state_path) ]]
	done
	export USAGE_CHECK_PROJECT=test-project USAGE_CHECK_MEMBER=member-a
	: >"$test_dir/calls.jsonl"
	(cd "$test_dir" && bash "$script")
	[[ ! -s $test_dir/calls.jsonl ]]
	[[ -s $USAGE_CHECK_STATE_ROOT/test-project/member-a.state
		&& -s $USAGE_CHECK_STATE_ROOT/test-project/member-b.state
		&& -s $USAGE_CHECK_STATE_ROOT/other-project/member-a.state ]]
	unset USAGE_CHECK_STATE_ROOT
	[[ $(usage_check_state_path) == "$HOME/.multica-agent/template/usage-check/test-project/member-a.state" ]]
)
echo 'PASS 記録の分離: プロジェクト・メンバーごとに通知し、元の組み合わせへ戻しても重複しない'

(
	export -f multica
	export test_dir USAGE_CHECK_ASSIGNEE USAGE_CHECK_PROJECT USAGE_CHECK_MEMBER
	export USAGE_CHECK_STATE_ROOT="$test_dir/states"
	state_file=$(usage_check_state_path)
	: >"$test_dir/comments.jsonl"
	echo '{"is_error":false,"result":"Current session: 100% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
	echo '[使用上限] Claude の Current session（claude:Current session）' >"$test_dir/get-title"
	touch "$test_dir/fail-comment"
	if (cd "$test_dir" && bash "$script") >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	grep -q 'mock comment failure' "$test_dir/err"
	jq -e '."claude:Current session" | .level == "warn"' "$state_file" >/dev/null
	[[ ! -s $test_dir/comments.jsonl ]]
	rm "$test_dir/fail-comment"
	(cd "$test_dir" && bash "$script")
	(cd "$test_dir" && bash "$script")
	jq -se 'length == 1 and (.[0].body | contains("使用上限に達した"))' "$test_dir/comments.jsonl" >/dev/null
	jq -e '."claude:Current session".level == "limited"' "$state_file" >/dev/null
	echo '{"is_error":false,"result":"Current session: 0% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
	(cd "$test_dir" && bash "$script")
	jq -e '."claude:Current session" == {level:"ok"}' "$state_file" >/dev/null
	for other in "$USAGE_CHECK_STATE_ROOT/test-project/member-b.state" "$USAGE_CHECK_STATE_ROOT/other-project/member-a.state"; do
		jq -e '."claude:Current session".level == "warn"' "$other" >/dev/null
	done
)
echo 'PASS 通知の失敗と復旧: 状態を進めず、再実行で一度通知し、ほかの組み合わせの記録を保つ'

echo 'PASS 本体: 別の作業ディレクトリから共通関数を読み、80% で警告し、同じ状態ではタスクを増やさない'

# 片方だけの PATH で本体を動かす。使わない側の警告を復旧扱いにしない。
for selected in claude codex; do
 (
	export -f multica
	export test_dir USAGE_CHECK_ASSIGNEE USAGE_CHECK_PROJECT USAGE_CHECK_MEMBER
	export USAGE_CHECK_RUNTIMES=$selected USAGE_CHECK_STATE_ROOT="$test_dir/$selected-states"
	selected_bin="$test_dir/$selected-bin"
	mkdir "$selected_bin"
	for tool in bash dirname mkdir mktemp jq python3 cat rm mv head seq grep cut date sleep; do
		ln -s "$(command -v "$tool")" "$selected_bin/$tool"
	done
	ln -s "$test_dir/bin/multica" "$selected_bin/multica"
	ln -s "$test_dir/bin/$selected" "$selected_bin/$selected"
	if [[ $selected == claude ]]; then disabled_key='codex:allowed'; else disabled_key='claude:Current session'; fi
	state_file=$(usage_check_state_path)
	mkdir -p "${state_file%/*}"
	jq -n --arg key "$disabled_key" '{($key):{level:"warn",issue: env.TEST_DISABLED_ID, labeled: true}}' >"$state_file"
	echo '{"is_error":false,"result":"Current session: 80% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
	echo '{"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{"codex":{"primary":{"windowDurationMins":10080,"usedPercent":80,"resetsAt":604800},"secondary":null}}}}' >"$test_dir/codex.jsonl"
	: >"$test_dir/calls.jsonl"; : >"$test_dir/runtime-calls"; : >"$test_dir/login-calls"
	if [[ $selected == claude ]]; then
		echo '[使用上限] Claude の Current session（claude:Current session）' >"$test_dir/get-title"
	else
		echo '[使用上限] Codex の codex の週の枠（codex:codex:10080）' >"$test_dir/get-title"
	fi
	cd "$test_dir"
	PATH="$selected_bin" /bin/bash "$script"
	grep -qx "$selected" "$test_dir/runtime-calls"
	[[ $(jq -Rsc 'split("\n")|map(select(length>0))|unique|length' "$test_dir/runtime-calls") == 1 ]]
	jq -se '[.[]|select(.[0:2]==["issue","create"])]|length==1' "$test_dir/calls.jsonl" >/dev/null
	jq -e --arg key "$disabled_key" '.[$key]=={level:"warn",issue: env.TEST_DISABLED_ID, labeled: true}' "$state_file" >/dev/null
	: >"$test_dir/calls.jsonl"
	PATH="$selected_bin" /bin/bash "$script"
	[[ ! -s $test_dir/calls.jsonl ]]
	echo '{"is_error":false,"result":"Current session: 0% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
	echo '{"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{}}}' >"$test_dir/codex.jsonl"
	: >"$test_dir/comments.jsonl"
	PATH="$selected_bin" /bin/bash "$script"
	jq -e --arg key "$disabled_key" '.[$key]=={level:"warn",issue: env.TEST_DISABLED_ID, labeled: true} and all(to_entries[]|select(.key!=$key); .value.level=="ok" and (.value | has("issue") | not))' "$state_file" >/dev/null
	jq -se '[.[]|select(.[0:2]==["issue","status"])]==[["issue","status",env.TEST_ISSUE_ID,"done","--no-start"]]' "$test_dir/calls.jsonl" >/dev/null
	# 見張るランタイムのログインだけを読む。
	if [[ $selected == claude ]]; then
		grep -qx claude-auth "$test_dir/login-calls"
		! grep -q '^codex-' "$test_dir/login-calls" || exit 1
	else
		grep -qx codex-login "$test_dir/login-calls"
		! grep -q '^claude-' "$test_dir/login-calls" || exit 1
	fi

	# 選んだ側がなければ、使用量や CLI を呼ぶ前に失敗する。
	rm "$selected_bin/$selected"
	: >"$test_dir/calls.jsonl"; : >"$test_dir/runtime-calls"
	state_before=$(cat "$state_file")
	if PATH="$selected_bin" /bin/bash "$script" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	grep -qF "$selected が見つからない" "$test_dir/err"
	[[ ! -s $test_dir/calls.jsonl && ! -s $test_dir/runtime-calls && $(cat "$state_file") == "$state_before" ]]
 )
 echo "PASS ランタイムの選択: $selected だけのコマンドで警告・復旧し、使わない側の状態を保ち、選んだ側の不足は事前に拒否する"
done

for invalid in '' other 'claude claude' 'claude codex other'; do
	: >"$test_dir/calls.jsonl"; : >"$test_dir/runtime-calls"
	if USAGE_CHECK_ASSIGNEE="$USAGE_CHECK_ASSIGNEE" USAGE_CHECK_PROJECT="$USAGE_CHECK_PROJECT" USAGE_CHECK_MEMBER="$USAGE_CHECK_MEMBER" USAGE_CHECK_RUNTIMES="$invalid" bash "$script" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	grep -q 'USAGE_CHECK_RUNTIMES は' "$test_dir/err"
	[[ ! -s $test_dir/calls.jsonl && ! -s $test_dir/runtime-calls ]]
done
echo 'PASS ランタイムの指定: 空・未知・重複した指定では、使用量とCLIを呼ぶ前に止まる'

# 未指定または空のプロジェクトでは、CLI や使用量の取得より前に止まる。
for project in unset empty; do
	if [[ $project == unset ]]; then
		if env -u USAGE_CHECK_PROJECT USAGE_CHECK_ASSIGNEE="$USAGE_CHECK_ASSIGNEE" bash "$script" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	else
		if USAGE_CHECK_PROJECT='' USAGE_CHECK_ASSIGNEE="$USAGE_CHECK_ASSIGNEE" bash "$script" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	fi
	grep -q 'USAGE_CHECK_PROJECT に、作るタスクを入れるプロジェクトの ID を渡す' "$test_dir/err"
	echo "PASS $project: プロジェクトがなければ実行前にエラー"
done

for member in unset empty; do
	if [[ $member == unset ]]; then
		if env -u USAGE_CHECK_MEMBER USAGE_CHECK_ASSIGNEE="$USAGE_CHECK_ASSIGNEE" USAGE_CHECK_PROJECT=test-project bash "$script" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	else
		if USAGE_CHECK_MEMBER='' USAGE_CHECK_ASSIGNEE="$USAGE_CHECK_ASSIGNEE" USAGE_CHECK_PROJECT=test-project bash "$script" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	fi
	grep -q 'USAGE_CHECK_MEMBER に、メンバーの区別を渡す' "$test_dir/err"
done
echo 'PASS メンバー: 未指定・空では記録や CLI の呼び出し前に止まる'

# 応答に UUID の形の id がなければ、行を変えず、同じ実行で起票し直さない。
for field in id identifier; do
	state='{}'
	: >"$test_dir/calls.jsonl"
	python3 "$root/tests/multica-fixture.py" "$test_dir" base issue-create |
		jq --arg field "$field" 'del(.[$field])' >"$test_dir/create-response.json"
	if apply claude:test-key warn 'テスト枠' '詳細' >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	grep -qF "issue-create の $field" "$test_dir/err"
	[[ $state == '{}' ]]
	jq -se 'length==1 and .[0][0:2]==["issue","create"]' "$test_dir/calls.jsonl" >/dev/null
done
state='{}'
: >"$test_dir/calls.jsonl"
python3 "$root/tests/multica-fixture.py" "$test_dir" base issue-create | jq '.id = "not-a-uuid"' >"$test_dir/create-response.json"
if apply claude:test-key warn 'テスト枠' '詳細' >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
grep -qF '起票したタスクの ID を確認できなかった' "$test_dir/err"
[[ $state == '{}' ]]
jq -se 'length==1 and .[0][0:2]==["issue","create"]' "$test_dir/calls.jsonl" >/dev/null
rm "$test_dir/create-response.json"
echo 'PASS 起票応答: id の欠落と UUID の形でない id は、行を変えず、起票の試行は一度だけ'

for field in id name resource_type; do
	state='{}'; task_failed=false
	: >"$test_dir/calls.jsonl"
	python3 "$root/tests/multica-fixture.py" "$test_dir" base label-list |
		jq --arg field "$field" '[del(.[$field])]' >"$test_dir/label-response.json"
	apply claude:test-key warn 'テスト枠' '詳細' >"$test_dir/out" 2>"$test_dir/err"
	grep -qF "label-list の $field" "$test_dir/err"
	[[ $task_failed == true ]]
	jq -se '[.[]|select(.[0:3]==["issue","label","add"])]|length==0' "$test_dir/calls.jsonl" >/dev/null
done
rm "$test_dir/label-response.json"
echo 'PASS ラベル応答: 必須欄の欠落は欄名で失敗し、ラベルを付けず、起票した行は labeled: false で保存する'

# 作るタスクの題は、キーの種類の始めで始まり、全角の括弧で囲んだキーで終わる。
task_failed=false
created_title() {
	jq -rs '[.[] | select(.[0:2] == ["issue", "create"])][0] | .[index("--title") + 1]' "$test_dir/calls.jsonl"
}
for case_ in 'claude:test-key|テスト枠|[使用上限] テスト枠（claude:test-key）' \
	'claude:fetch|Claude の使用量を取れない|[使用上限] Claude の使用量を取れない（claude:fetch）' \
	'codex:codex:300|Codex の codex の5 時間の枠|[使用上限] Codex の codex の5 時間の枠（codex:codex:300）' \
	'login:claude|Claude Code のログイン|[ログイン] Claude Code のログイン（login:claude）'; do
	IFS='|' read -r key title expected <<<"$case_"
	state='{}'
	: >"$test_dir/calls.jsonl"
	apply "$key" error "$title" '詳細'
	[[ $(created_title) == "$expected" ]]
	jq -e --arg k "$key" '.[$k] == {level: "error", issue: env.TEST_ISSUE_ID, labeled: true}' "$STATE_FILE" >/dev/null
done
echo 'PASS 題のキー: 作るタスクの題が、キーの種類の始めで始まり、全角の括弧で囲んだキーで終わる'

# 更新する前のタスクの確認。合うタスクは、コメントも done もできる。
comment_count() { [[ -f $test_dir/comments.jsonl ]] && jq -s 'length' "$test_dir/comments.jsonl" || echo 0; }
reset_server() {
	rm -f "$test_dir/get-override.json" "$test_dir/fail-get" "$test_dir/hang-get" \
		"$test_dir/fail-update" "$test_dir/fail-comment" "$test_dir/fail-create-prefix" \
		"$test_dir/fail-label" "$test_dir/fail-label-list" "$test_dir/fail-done" "$test_dir/label-response.json" \
		"$test_dir/check-saved-id" "$test_dir/saved-id-checked" "$test_dir/check-pairs" \
		"$test_dir/create-response.json"
	: >"$test_dir/calls.jsonl"
	: >"$test_dir/comments.jsonl"
	: >"$test_dir/updates.jsonl"
	: >"$test_dir/responses.jsonl"
	task_failed=false
}
reset_server
echo '[使用上限] テスト枠（claude:test-key）' >"$test_dir/get-title"
state=$(jq -nc '{"claude:test-key":{"level":"warn","issue":env.TEST_ISSUE_ID}}')
apply claude:test-key ok 'テスト枠' '詳細' 2>"$test_dir/err"
[[ $task_failed == false && $(comment_count) == 1 && ! -s $test_dir/err ]]
jq -se '[.[] | select(.[0:2] == ["issue", "get"])] == [["issue","get",env.TEST_ISSUE_ID,"--output","json"]]
	and [.[] | select(.[0:2] == ["issue", "status"])] == [["issue","status",env.TEST_ISSUE_ID,"done","--no-start"]]' "$test_dir/calls.jsonl" >/dev/null
echo 'PASS 更新の前の確認: 合うタスクは、サーバーのタスクを読んだうえでコメントし done にする'

# プロジェクト・作者・題の始め・題の終わりのキーのどれかが違えば、コメントも done もせず、状態から外して 1 で終える。
# 閉じてよいタスクとして ID を書くのは、題にキーのない前のバージョンのタスクだけ（closable に yes を渡す）。
mismatch_case() { # 名前 キー 題 差し替えの JSON 新しい状態 [closable]
	local name=$1 key=$2 title=$3 override=$4 level=$5 closable=${6-no}
	reset_server
	echo "$title" >"$test_dir/get-title"
	echo "$override" >"$test_dir/get-override.json"
	state=$(jq -n --arg k "$key" '{($k): {level: "warn", issue: env.TEST_ISSUE_ID, labeled: true}, other: {level: "warn", issue: env.TEST_OTHER_ID, labeled: true}}')
	apply "$key" "$level" '枠' '詳細' 2>"$test_dir/err"
	if [[ $task_failed != true || $(comment_count) != 0 ]]; then echo "FAIL $name: 更新したか、失敗にしていない" >&2; exit 1; fi
	jq -se '[.[] | select(.[0:2] == ["issue", "status"] or .[0:2] == ["issue", "comment"])] | length == 0' "$test_dir/calls.jsonl" >/dev/null
	jq -e --arg k "$key" 'has($k) | not' <<<"$state" >/dev/null
	jq -e '.other == {level: "warn", issue: env.TEST_OTHER_ID, labeled: true}' <<<"$state" >/dev/null
	jq -e --arg k "$key" 'has($k) | not' "$STATE_FILE" >/dev/null
	grep -qF "状態から外した" "$test_dir/err"
	if [[ $closable == yes ]]; then
		grep -qxF "閉じてよいタスク: $TEST_ISSUE_ID" "$test_dir/err"
	else
		! grep -q "閉じてよいタスク" "$test_dir/err"
	fi
	echo "PASS 更新の前の確認: $name は更新せず、状態から外して失敗にする"
}
for level in limited ok; do
	t='[使用上限] 枠（claude:test-key）'
	mismatch_case "別のプロジェクト（${level}）" claude:test-key "$t" '{"project_id":"other-project"}' "$level"
	mismatch_case "人の作者（${level}）" claude:test-key "$t" '{"creator_type":"member"}' "$level"
	mismatch_case "別のエージェントの作者（${level}）" claude:test-key "$t" '{"creator_id":"other-agent"}' "$level"
	mismatch_case "題の始めが違う（${level}）" claude:test-key '人が書き換えた題（claude:test-key）' '{}' "$level"
	mismatch_case "題の始めの空白がない（${level}）" claude:test-key '[使用上限]枠（claude:test-key）' '{}' "$level"
	mismatch_case "題が空（${level}）" claude:test-key '' '{"title":null}' "$level"
	mismatch_case "キーが題の終わりにない（${level}）" claude:test-key '[使用上限] 枠（claude:test-key）メモ' '{}' "$level" yes
	mismatch_case "キーの括弧が半角（${level}）" claude:test-key '[使用上限] 枠(claude:test-key)' '{}' "$level" yes
	# 同じ見張りが同じプロジェクトに作った、別のキーのタスクを更新しない。
	mismatch_case "キーが fetch と枠で違う（${level}）" claude:fetch '[使用上限] Claude の Current session（claude:Current session）' '{}' "$level"
	mismatch_case "キーが枠と fetch で違う（${level}）" 'claude:Current session' '[使用上限] Claude の使用量を取れない（claude:fetch）' '{}' "$level"
	mismatch_case "キーが枠どうしで違う（${level}）" 'codex:codex:300' '[使用上限] Codex の codex の週の枠（codex:codex:10080）' '{}' "$level"
	mismatch_case "login:claude に login:codex のタスク（${level}）" login:claude '[ログイン] Codex のログイン（login:codex）' '{}' "$level"
	mismatch_case "login:codex に login:claude のタスク（${level}）" login:codex '[ログイン] Claude Code のログイン（login:claude）' '{}' "$level"
	mismatch_case "ログインのキーに使用上限の題（${level}）" login:claude '[使用上限] 枠（login:claude）' '{}' "$level"
	mismatch_case "使用上限のキーにログインの題（${level}）" claude:test-key '[ログイン] 枠（claude:test-key）' '{}' "$level"
done
# 自分の ID が分からなければ、作者を確認できないので合わない。
(
	unset MULTICA_AGENT_ID
	reset_server
	echo '[使用上限] 枠（claude:test-key）' >"$test_dir/get-title"
	echo '{"creator_id":""}' >"$test_dir/get-override.json"
	state=$(jq -nc '{"claude:test-key":{"level":"warn","issue":env.TEST_ISSUE_ID}}')
	apply claude:test-key limited '枠' '詳細' 2>"$test_dir/err"
	[[ $task_failed == true && $(comment_count) == 0 ]]
)
echo 'PASS 更新の前の確認: MULTICA_AGENT_ID がなければ作者が合わず、更新しない'

# サーバーのタスクを読めなければ、状態を変えず、更新せずに失敗する（外した扱いにもしない）。
reset_server
touch "$test_dir/fail-get"
state=$(jq -nc '{"claude:test-key":{"level":"warn","issue":env.TEST_ISSUE_ID}}')
state_before=$state
apply claude:test-key limited '枠' '詳細' >"$test_dir/out" 2>"$test_dir/err"
rm "$test_dir/fail-get"
grep -qF 'サーバーから読めなかった' "$test_dir/err"
[[ $state == "$state_before" && $task_failed == true && $(comment_count) == 0 ]]
echo 'PASS 更新の前の確認: タスクを読めないときは、状態を変えず更新もせず、失敗にして次の行へ進む'

# ok でない状態どうしの変化は、新しい状態の始めの文をコメントする。
transition_case() { # キー 題 前の状態 新しい状態 コメントの始めの文
	local key=$1 title=$2 prev=$3 level=$4 sentence=$5
	reset_server
	echo "$title" >"$test_dir/get-title"
	state=$(jq -n --arg k "$key" --arg l "$prev" '{($k): {level: $l, issue: env.TEST_ISSUE_ID, labeled: true}}')
	apply "$key" "$level" '枠' '詳細の文' 2>"$test_dir/err"
	[[ $task_failed == false && ! -s $test_dir/err ]]
	jq -se --arg t "$(title_prefix "$key") 枠（${key}）" --arg s "$sentence" \
		'length == 1 and .[0].title == $t and (.[0].description | startswith($s + "\n\n詳細の文\n"))' "$test_dir/updates.jsonl" >/dev/null
	jq -se --arg s "$sentence" 'length == 1 and (.[0].body | startswith($s + "。\n\n") and contains("詳細の文"))' "$test_dir/comments.jsonl" >/dev/null
	jq -se '[.[] | select(.[0:2] == ["issue", "status"])] | length == 0' "$test_dir/calls.jsonl" >/dev/null
	jq -e --arg k "$key" --arg l "$level" '.[$k] == {level: $l, issue: env.TEST_ISSUE_ID, labeled: true}' <<<"$state" >/dev/null
	echo "PASS 状態の変化: $key の $prev から $level で、新しい状態の文をコメントする"
}
t='[使用上限] 枠（claude:test-key）'
transition_case claude:test-key "$t" warn error '使用量を取れなくなり、見張れていない。ログインや表示の形が変わっていないか確認する'
transition_case claude:test-key "$t" error warn '使用上限が近い。重い作業の割り振りを控えるか、エージェントを別の系統のモデルに寄せる'
l='[ログイン] 枠（login:claude）'
transition_case login:claude "$l" warn error 'ログインしていない。このツールの役はすべて失敗する'
transition_case login:claude "$l" error unverified 'ログインを確認できない。バージョンとログインを確認する'
transition_case login:claude "$l" unverified error 'ログインしていない。このツールの役はすべて失敗する'
transition_case login:claude "$l" warn unverified 'ログインを確認できない。バージョンとログインを確認する'

# 本体を通した確認。状態のファイルが別のプロジェクトのタスクを指していれば、更新せず、状態から外して 1 で終える。
(
	export -f multica
	export test_dir USAGE_CHECK_ASSIGNEE USAGE_CHECK_PROJECT USAGE_CHECK_MEMBER MULTICA_AGENT_ID
	export USAGE_CHECK_STATE_ROOT="$test_dir/verify-states" USAGE_CHECK_RUNTIMES=claude USAGE_WARN_PERCENT
	state_file=$(usage_check_state_path)
	mkdir -p "${state_file%/*}"
	reset_server
	echo '[使用上限] Claude の Current session（claude:Current session）' >"$test_dir/get-title"
	echo '{"project_id":"other-project"}' >"$test_dir/get-override.json"
	jq -n '{"claude:Current session": {level: "warn", issue: env.TEST_ISSUE_ID, labeled: true}}' >"$state_file"
	echo '{"is_error":false,"result":"Current session: 100% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
	if (cd "$test_dir" && bash "$script") >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	grep -qF '状態から外した' "$test_dir/err"
	[[ $(comment_count) == 0 ]]
	jq -e 'has("claude:Current session") | not' "$state_file" >/dev/null
	jq -se '[.[] | select(.[0:2] == ["issue", "status"] or .[0:2] == ["issue", "comment"] or .[0:2] == ["issue", "create"])] | length == 0' "$test_dir/calls.jsonl" >/dev/null
	# 次の実行は、外れたキーを新しい題（キー付き）で作り直す。
	: >"$test_dir/calls.jsonl"
	rm "$test_dir/get-override.json"
	(cd "$test_dir" && bash "$script")
	[[ $(created_title) == '[使用上限] Claude の Current session（claude:Current session）' ]]
	jq -e '."claude:Current session".level == "limited"' "$state_file" >/dev/null
)
echo 'PASS 本体: 合わないタスクを更新せず、状態から外して 1 で終える。同じ実行では書き戻さず、次の実行で題にキーを付けて作り直す'

# ===== ログインの行 =====
login_state_file() { printf '%s/login-states/%s/%s.state\n' "$test_dir" "$USAGE_CHECK_PROJECT" "$USAGE_CHECK_MEMBER"; }
usage_zero='{"is_error":false,"result":"Current session: 0% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}'
login_title='[ログイン] Claude Code のログイン（login:claude）'
codex_login_title='[ログイン] Codex のログイン（login:codex）'
login_reset() {
	reset_server
	rm -f "$(login_state_file)" "$test_dir/description.md" "$test_dir/create-response.json" \
		"$test_dir/claude-auth-hang" "$test_dir/codex-login-hang"
	: >"$test_dir/runtime-calls"; : >"$test_dir/login-calls"
	echo "$usage_zero" >"$test_dir/claude.json"; echo 0 >"$test_dir/claude.status"
	echo '2.1.322 (Claude Code)' >"$test_dir/claude-version"
	rm -f "$test_dir/claude-version.status"
	claude_auth 0 '{"loggedIn":true,"authMethod":"claude.ai","email":"fake.person@example.invalid","orgName":"Fake Org Inc"}'
	codex_login 0 'Logged in using ChatGPT'
	echo '{"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{}}}' >"$test_dir/codex.jsonl"
}
# 本体を、ログインの状態のファイルで動かす。stdout と stderr は out と err に置く。
login_run() { # [見張るランタイム] [環境変数...]
	local runtimes=${1:-claude}
	shift || true
	(
		export -f multica
		export test_dir USAGE_CHECK_ASSIGNEE USAGE_CHECK_PROJECT USAGE_CHECK_MEMBER MULTICA_AGENT_ID USAGE_WARN_PERCENT
		export USAGE_CHECK_STATE_ROOT="$test_dir/login-states" USAGE_CHECK_RUNTIMES=$runtimes
		cd "$test_dir" && env "$@" bash "$script"
	) >"$test_dir/out" 2>"$test_dir/err"
}
# 偽のメールアドレスと組織が、stdout・stderr・状態のファイル・タスクの本文・コメント・CLI の呼び出しのどこにもないこと。
assert_no_leak() {
	local file
	for file in out err description.md comments.jsonl calls.jsonl; do
		[[ -f $test_dir/$file ]] || continue
		if grep -qE 'fake\.person|example\.invalid|Fake Org' "$test_dir/$file"; then echo "FAIL: ${file} に偽のメールアドレスか組織がある" >&2; exit 1; fi
	done
	if [[ -f $(login_state_file) ]] && grep -qE 'fake\.person|example\.invalid|Fake Org' "$(login_state_file)"; then
		echo 'FAIL: 状態のファイルに偽のメールアドレスか組織がある' >&2; exit 1
	fi
}
expiry_json() { # 期限までの日数 [ms]
	python3 - "$@" <<'PY'
import json
import sys
import time
from datetime import datetime, timezone

at = time.time() + float(sys.argv[1]) * 86400
value = int(at * 1000) if len(sys.argv) > 2 else datetime.fromtimestamp(at, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")
print(json.dumps({"loggedIn": True, "authMethod": "claude.ai", "email": "fake.person@example.invalid",
	"orgName": "Fake Org Inc", "loginExpiresAt": value}))
PY
}
assert_initial_login_ok() {
	jq -se '[.[] | select(.[0:2] == ["issue", "create"])] | length == 0' "$test_dir/calls.jsonl" >/dev/null
	jq -e --arg key "login:$1" '.[$key] == {level: "ok"}' "$(login_state_file)" >/dev/null
}
sentence_warn='期限が近い。期限の前に、manual.md の手順でログインし直す'
sentence_error='ログインしていない。このツールの役はすべて失敗する'
sentence_unverified='ログインを確認できない。バージョンとログインを確認する'

# 4 つの状態。名前|バージョン|終了コード|JSON|状態|題|始めの文|説明に含む文字
login_state_case() {
	local name=$1 version=$2 code=$3 json=$4 level=$5 title=${6-} sentence=${7-} detail=${8-}
	login_reset
	echo "$version" >"$test_dir/claude-version"
	claude_auth "$code" "$json"
	login_run
	if [[ $level == ok ]]; then
		assert_initial_login_ok claude
	else
		[[ $(created_title) == "[ログイン] ${title}（login:claude）" ]]
		jq -e --arg l "$level" '."login:claude" == {level: $l, issue: env.TEST_ISSUE_ID, labeled: true}' "$(login_state_file)" >/dev/null
		[[ $(head -n 1 "$test_dir/description.md") == "$sentence" ]]
		[[ -z $detail ]] || grep -qE -- "$detail" "$test_dir/description.md"
	fi
	assert_no_leak
	echo "PASS ログインの状態: ${name}は ${level}"
}
logged_in='{"loggedIn":true,"authMethod":"claude.ai","email":"fake.person@example.invalid","orgName":"Fake Org Inc"}'
login_state_case '期限がない' '2.1.322 (Claude Code)' 0 "$logged_in" ok ''
login_state_case '期限まで 30 日' '2.1.322 (Claude Code)' 0 "$(expiry_json 30)" ok ''
login_state_case '期限まで 11 日' '2.1.322 (Claude Code)' 0 "$(expiry_json 11)" ok ''
login_state_case '期限まで 9 日' '2.1.322 (Claude Code)' 0 "$(expiry_json 9)" warn 'Claude Code のログインの期限' "$sentence_warn" '期限は [0-9]{4}-[0-9]{2}-[0-9]{2}、残り 8 日'
login_state_case '期限まで 1 日（ミリ秒の数）' '2.1.322 (Claude Code)' 0 "$(expiry_json 1.5 ms)" warn 'Claude Code のログインの期限' "$sentence_warn" '残り 1 日'
login_state_case '期限を過ぎた' '2.1.322 (Claude Code)' 0 "$(expiry_json -1)" error 'Claude Code のログイン' "$sentence_error" '期限を過ぎた'
login_state_case '終了コード 1 で loggedIn が false' '2.1.322 (Claude Code)' 1 '{"loggedIn":false,"email":"fake.person@example.invalid"}' error 'Claude Code のログイン' "$sentence_error" '終了コード 1'
login_state_case '最低より古いバージョン' '2.1.321 (Claude Code)' 0 "$logged_in" unverified 'Claude Code のログインを確認できない' "$sentence_unverified" '2\.1\.321 は、最低のバージョン 2\.1\.322 より古い'
login_state_case '新しいバージョン' '2.2.0 (Claude Code)' 0 "$logged_in" ok ''
login_state_case 'バージョンを読めない' 'Claude Code' 0 "$logged_in" unverified 'Claude Code のログインを確認できない' "$sentence_unverified" 'バージョンを読めない'
login_state_case '終了コード 2' '2.1.322' 2 "$logged_in" unverified 'Claude Code のログインを確認できない' "$sentence_unverified" '終了コード 2'
login_state_case '終了コード 1 で loggedIn がない' '2.1.322' 1 '{"email":"fake.person@example.invalid"}' unverified 'Claude Code のログインを確認できない' "$sentence_unverified" '終了コード 1'
login_state_case '終了コード 1 で JSON でない' '2.1.322' 1 'fake.person@example.invalid' unverified 'Claude Code のログインを確認できない' "$sentence_unverified" '終了コード 1'
login_state_case '終了コード 0 で JSON でない' '2.1.322' 0 'fake.person@example.invalid' unverified 'Claude Code のログインを確認できない' "$sentence_unverified" 'JSON として読めない'
login_state_case '終了コード 0 で JSON が配列' '2.1.322' 0 '[1]' unverified 'Claude Code のログインを確認できない' "$sentence_unverified" 'JSON として読めない'
login_state_case '終了コード 0 で loggedIn が false' '2.1.322' 0 '{"loggedIn":false}' unverified 'Claude Code のログインを確認できない' "$sentence_unverified" 'loggedIn が true でない'
login_state_case '終了コード 0 で期限を読めない' '2.1.322' 0 '{"loggedIn":true,"loginExpiresAt":"来週"}' unverified 'Claude Code のログインを確認できない' "$sentence_unverified" '期限を日時として読めない'

# 時間切れは確認失敗にする。
login_reset
touch "$test_dir/claude-auth-hang"
login_run claude USAGE_LOGIN_READ_SECONDS=1
[[ $(created_title) == '[ログイン] Claude Code のログインを確認できない（login:claude）' ]]
grep -qx 'claude auth status --json が時間切れになった' "$test_dir/description.md"
assert_no_leak
echo 'PASS ログインの状態: 時間切れは確認失敗'

# 警告の日数は USAGE_LOGIN_WARN_DAYS で変える。数でない値は、何も呼ぶ前に止まる。
login_reset
claude_auth 0 "$(expiry_json 15)"
login_run claude USAGE_LOGIN_WARN_DAYS=20
jq -e '."login:claude".level == "warn"' "$(login_state_file)" >/dev/null
login_reset
claude_auth 0 "$(expiry_json 15)"
login_run claude
assert_initial_login_ok claude
login_reset
if login_run claude USAGE_LOGIN_WARN_DAYS=abc; then exit 1; fi
grep -q 'USAGE_LOGIN_WARN_DAYS には' "$test_dir/err"
[[ ! -s $test_dir/login-calls && ! -s $test_dir/calls.jsonl ]]
echo 'PASS ログインの警告の日数: USAGE_LOGIN_WARN_DAYS で変わり、数でない値は止まる'

# 見張らないランタイムには、ログインの行もタスクもできない。claude と codex の両方を見るときは、claude の行ができる。
login_reset
claude_auth 1 '{"loggedIn":false}'
login_run codex
[[ $(cat "$test_dir/login-calls") == codex-login ]]
assert_initial_login_ok codex
jq -e 'has("login:claude") | not' "$(login_state_file)" >/dev/null
login_run 'claude codex'
[[ $(created_title) == "$login_title" ]]
jq -e '."login:claude".level == "error"' "$(login_state_file)" >/dev/null
assert_no_leak
echo 'PASS ログインの行: 見張らないランタイムには行もタスクもできない'

# 戻るとき。前回が warn・error・確認失敗で、ローカルでは ok のとき。
login_prev_state() { # 前の状態
	jq -n --arg l "$1" '{"login:claude": {level: $l, issue: env.TEST_LOGIN_ID, labeled: true}}' >"$(login_state_file)"
	echo "$login_title" >"$test_dir/get-title"
}
for prev in warn error unverified; do
	# 同じ実行で使用量を読めれば、「ログインし直された」とコメントして done にする。
	login_reset
	mkdir -p "$(dirname "$(login_state_file)")"
	login_prev_state "$prev"
	login_run
	jq -se 'length == 1 and (.[0].body | startswith("ログインし直された。\n\n"))' "$test_dir/comments.jsonl" >/dev/null
	jq -se '[.[] | select(.[0:2] == ["issue", "status"])] == [["issue","status",env.TEST_LOGIN_ID,"done","--no-start"]]' "$test_dir/calls.jsonl" >/dev/null
	jq -e '."login:claude" == {level: "ok"}' "$(login_state_file)" >/dev/null
	grep -qx claude "$test_dir/runtime-calls"
	assert_no_leak

	# 使用量を読めなければ、前回の状態のまま、コメントも done もしない。
	login_reset
	mkdir -p "$(dirname "$(login_state_file)")"
	login_prev_state "$prev"
	echo 1 >"$test_dir/claude.status"; echo 'ログイン済みでも使えない' >"$test_dir/claude.json"
	login_run
	jq -e --arg l "$prev" '."login:claude" == {level: $l, issue: env.TEST_LOGIN_ID, labeled: true}' "$(login_state_file)" >/dev/null
	[[ $(comment_count) == 0 ]]
	jq -se '[.[] | select(.[0:2] == ["issue", "status"] or .[0:2] == ["issue", "comment"])] | length == 0' "$test_dir/calls.jsonl" >/dev/null
	grep -qx claude "$test_dir/runtime-calls"
	assert_no_leak
	echo "PASS ログインの戻り: ${prev} から、使用量を読めたときだけ ok に戻し、読めなければ前回のまま"
done

# error のツールは使用率を読まず、使用上限の行を前回のままにする。確認失敗のツールは使用率を読む。
login_reset
mkdir -p "$(dirname "$(login_state_file)")"
jq -n '{"login:claude": {level: "error", issue: env.TEST_LOGIN_ID, labeled: true}, "claude:Current session": {level: "warn", issue: env.TEST_USAGE_ID, labeled: true}}' >"$(login_state_file)"
echo "$login_title" >"$test_dir/get-title"
claude_auth 1 '{"loggedIn":false,"email":"fake.person@example.invalid"}'
login_run
[[ ! -s $test_dir/runtime-calls ]]
jq -e '. == {"login:claude": {level: "error", issue: env.TEST_LOGIN_ID, labeled: true}, "claude:Current session": {level: "warn", issue: env.TEST_USAGE_ID, labeled: true}}' "$(login_state_file)" >/dev/null
[[ $(comment_count) == 0 ]]
jq -se '[.[] | select(.[0:2] == ["issue", "status"] or .[0:2] == ["issue", "comment"] or .[0:2] == ["issue", "create"])] | length == 0' "$test_dir/calls.jsonl" >/dev/null
assert_no_leak
login_reset
mkdir -p "$(dirname "$(login_state_file)")"
jq -n '{"claude:Current session": {level: "warn", issue: env.TEST_USAGE_ID, labeled: true}}' >"$(login_state_file)"
echo '[使用上限] Claude の Current session（claude:Current session）' >"$test_dir/get-title"
claude_auth 2 "$logged_in"
login_run
grep -qx claude "$test_dir/runtime-calls"
jq -e '."claude:Current session" == {level: "ok"} and ."login:claude".level == "unverified"' "$(login_state_file)" >/dev/null
jq -se 'length == 1 and (.[0].body | startswith("リセットされた"))' "$test_dir/comments.jsonl" >/dev/null
assert_no_leak
echo 'PASS ログインの行: error のツールは使用率を読まず、使用上限の行を前回のままにする。確認失敗のツールは読む'

# Codex の終了コードと出力の組み合わせ。終了コード 1 の定型文だけを未ログインとする。
codex_login_case() {
	local code=$1 output=$2 level=$3 title=$4 sentence=$5
	login_reset
	codex_login "$code" "$output"
	login_run codex
	[[ $(cat "$test_dir/login-calls") == codex-login ]]
	[[ $(created_title) == "$title" ]]
	jq -e --arg level "$level" '."login:codex" == {level: $level, issue: env.TEST_ISSUE_ID, labeled: true}' "$(login_state_file)" >/dev/null
	[[ $(head -n 1 "$test_dir/description.md") == "$sentence" ]]
	grep -q "終了コード $code" "$test_dir/description.md"
	assert_no_leak
}
codex_unverified_title='[ログイン] Codex のログインを確認できない（login:codex）'
codex_login_case 1 'Not logged in' error "$codex_login_title" "$sentence_error"
[[ ! -s $test_dir/runtime-calls ]]
codex_login_case 1 'Not logged in: fake.person@example.invalid' unverified "$codex_unverified_title" "$sentence_unverified"
[[ $(cat "$test_dir/runtime-calls") == codex ]]
codex_login_case 2 'Not logged in' unverified "$codex_unverified_title" "$sentence_unverified"
echo 'PASS Codex のログイン: 終了コード 1 と定型文で error になり、確認失敗では使用量を読む'

login_reset
codex_login 0 'fake.person@example.invalid'
touch "$test_dir/codex-login-hang"
login_run codex USAGE_LOGIN_READ_SECONDS=1
[[ $(created_title) == "$codex_unverified_title" ]]
grep -qx 'codex login status が時間切れになった' "$test_dir/description.md"
assert_no_leak
echo 'PASS Codex のログイン: 時間切れは確認失敗'

# Codex の使用量を読めない場合は、同じ実行で Claude の使用量を読めても復旧扱いにしない。
for prev in error unverified; do
	login_reset
	mkdir -p "$(dirname "$(login_state_file)")"
	jq -n --arg level "$prev" '{"login:codex": {level: $level, issue: env.TEST_LOGIN_ID, labeled: true}, "codex:allowed": {level: "warn", issue: env.TEST_USAGE_ID, labeled: true}}' >"$(login_state_file)"
	echo "$codex_login_title" >"$test_dir/get-title"
	if [[ $prev == error ]]; then
		codex_login 1 'Not logged in'
		login_run codex
		[[ ! -s $test_dir/runtime-calls && ! -s $test_dir/calls.jsonl ]]
		jq -e '."codex:allowed" == {level: "warn", issue: env.TEST_USAGE_ID, labeled: true}' "$(login_state_file)" >/dev/null
	fi
	# 使用量の行を初期化し、ログインの復旧を読む。
	jq -n --arg level "$prev" '{"login:codex": {level: $level, issue: env.TEST_LOGIN_ID, labeled: true}}' >"$(login_state_file)"
	codex_login 0 'fake.person@example.invalid'
	cp "$test_dir/codex.jsonl" "$test_dir/codex-ok.jsonl"
	echo '{"id":2,"error":{"message":"ログインが必要"}}' >"$test_dir/codex.jsonl"
	login_run 'claude codex'
	[[ $(cat "$test_dir/runtime-calls") == $'claude\ncodex' ]]
	jq -e --arg level "$prev" '."login:codex" == {level: $level, issue: env.TEST_LOGIN_ID, labeled: true} and ."codex:fetch".level == "error"' "$(login_state_file)" >/dev/null
	jq -se 'all(.[]; .[0:2] != ["issue", "comment"] and .[0:2] != ["issue", "status"])' "$test_dir/calls.jsonl" >/dev/null
	assert_no_leak
	reset_server
	mv "$test_dir/codex-ok.jsonl" "$test_dir/codex.jsonl"
	# 使用量の取得エラーのタスクは別キー。ログインの更新だけを確認する。
	jq -n --arg level "$prev" '{"login:codex": {level: $level, issue: env.TEST_LOGIN_ID, labeled: true}}' >"$(login_state_file)"
	echo "$codex_login_title" >"$test_dir/get-title"
	login_run codex
	jq -e '."login:codex" == {level: "ok"}' "$(login_state_file)" >/dev/null
	jq -se 'length == 1 and (.[0].body | startswith("ログインし直された。\n\n"))' "$test_dir/comments.jsonl" >/dev/null
	jq -se '[.[] | select(.[0:2] == ["issue", "status"])] == [["issue","status",env.TEST_LOGIN_ID,"done","--no-start"]]' "$test_dir/calls.jsonl" >/dev/null
	assert_no_leak
	echo "PASS Codex のログインの戻り: ${prev} から、同じ実行で Codex の使用量を読めたときだけ ok に戻す"
done

# claude --version が 0 以外で終わるときと、期限が日時にできない大きな値のときは、確認失敗にし、トレースバックを出さない。
login_reset
echo 3 >"$test_dir/claude-version.status"
login_run
[[ $(created_title) == '[ログイン] Claude Code のログインを確認できない（login:claude）' ]]
grep -qx 'claude --version が終了コード 3 で終わった' "$test_dir/description.md"
! grep -q Traceback "$test_dir/err"
assert_no_leak
login_reset
claude_auth 0 '{"loggedIn":true,"authMethod":"claude.ai","email":"fake.person@example.invalid","loginExpiresAt":1e80}'
login_run
[[ $(created_title) == '[ログイン] Claude Code のログインを確認できない（login:claude）' ]]
grep -q '期限を日時として読めない' "$test_dir/description.md"
! grep -q Traceback "$test_dir/err"
assert_no_leak
echo 'PASS ログインの状態: claude --version の失敗と期限の大きな値は確認失敗で、トレースバックを出さない'


# ok でない状態どうしの変化は、題と本文を書き換える。limited から warn でも書き換え、コメントは「戻った」にする。
reset_server
echo '[使用上限] 枠（claude:test-key）' >"$test_dir/get-title"
state=$(jq -nc '{"claude:test-key":{"level":"limited","issue":env.TEST_ISSUE_ID,"labeled":true}}')
apply claude:test-key warn '枠' '詳細の文' 2>"$test_dir/err"
jq -se '.[0].title == "[使用上限] 枠（claude:test-key）" and (.[0].description | startswith("使用上限が近い。"))' "$test_dir/updates.jsonl" >/dev/null
jq -se 'length == 1 and (.[0].body | startswith("戻った。"))' "$test_dir/comments.jsonl" >/dev/null
jq -e '."claude:test-key" == {level: "warn", issue: env.TEST_ISSUE_ID, labeled: true}' <<<"$state" >/dev/null
echo 'PASS 題と本文の書き換え: limited から warn でも書き換え、「戻った」をコメントする'

# 書き換えに失敗したら、コメントも level の保存もせず、失敗にする。次の実行が書き換えからやり直す。
reset_server
echo '[使用上限] 枠（claude:test-key）' >"$test_dir/get-title"
touch "$test_dir/fail-update"
state=$(jq -nc '{"claude:test-key":{"level":"warn","issue":env.TEST_ISSUE_ID,"labeled":true}}')
state_before=$state
apply claude:test-key error '枠' '詳細の文' 2>"$test_dir/err"
grep -qF '書き換えられなかった' "$test_dir/err"
[[ $task_failed == true && $(comment_count) == 0 && $state == "$state_before" ]]
rm "$test_dir/fail-update"
task_failed=false
apply claude:test-key error '枠' '詳細の文' 2>"$test_dir/err"
[[ $task_failed == false && $(comment_count) == 1 ]]
jq -se 'length == 1 and (.[0].description | startswith("使用量を取れなくなり"))' "$test_dir/updates.jsonl" >/dev/null
jq -e '."claude:test-key" == {level: "error", issue: env.TEST_ISSUE_ID, labeled: true}' <<<"$state" >/dev/null
reset_server
echo 'PASS 題と本文の書き換え: 失敗したら行を変えず、次の実行で書き換えからやり直す'

# タスクのない行は、観測が ok なら、ログインの行だけ ok を記録し、それ以外は行を増やさない。
reset_server
state='{}'
apply claude:test-key ok '枠' '詳細'
[[ $state == '{}' && ! -s $test_dir/calls.jsonl ]]
apply login:claude ok 'ログイン' '詳細'
jq -e '. == {"login:claude": {level: "ok"}}' <<<"$state" >/dev/null
[[ ! -s $test_dir/calls.jsonl ]]
echo 'PASS タスクのない行: ok の観測は、ログインの行だけ記録し、呼び出しをしない'

# 起票できても、ID を状態に保存できなければ、閉じてよいタスクとして ID を書き、ラベルを付けずに失敗する。
eval "real_$(declare -f save_state)"
save_fail_once=
save_state() {
	if [[ -n $save_fail_once ]] && jq -e --arg k "$save_fail_once" 'has($k)' <<<"$1" >/dev/null 2>&1; then
		save_fail_once=
		return 1
	fi
	real_save_state "$@"
}
reset_server
state='{}'
rm -f "$STATE_FILE"
save_fail_once=claude:test-key
if apply claude:test-key warn '枠' '詳細' >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
grep -qxF "起票したタスク ${TEST_ISSUE_ID} を状態に保存できなかった。閉じてよいタスク: ${TEST_ISSUE_ID}" "$test_dir/err"
[[ $state == '{}' && ! -e $STATE_FILE ]]
jq -se '[.[] | select(.[0:3] == ["issue", "label", "add"])] | length == 0' "$test_dir/calls.jsonl" >/dev/null
echo 'PASS 起票の保存: ID を保存できなければ、閉じてよいタスクとして書き、ラベルを付けず失敗にする'

# ===== 失敗した操作のやり直し =====
# 観測は login:claude を使い、後続の正常な Codex の行まで処理できたことも見る。
observe_login() {
	case $1 in
	ok) claude_auth 0 "$logged_in" ;;
	warn) claude_auth 0 "$(expiry_json 3)" ;;
	error) claude_auth 1 '{"loggedIn":false}' ;;
	unverified) claude_auth 2 "$logged_in" ;;
	esac
}

# 書き込みより前の正常な応答に、対象のキーと ID の組があることを確認する。
assert_verified_writes() {
	jq -se --arg project "$USAGE_CHECK_PROJECT" --arg agent "$MULTICA_AGENT_ID" --slurpfile responses "$test_dir/responses.jsonl" '
		def target:
			if .[0:3] == ["issue", "label", "add"] or .[0:3] == ["issue", "comment", "add"] then .[3]
			elif .[0:2] == ["issue", "update"] or .[0:2] == ["issue", "status"] then .[2]
			else empty end;
		. as $calls | all(to_entries[] | . as $call | ($call.value | target) | {index: $call.key, id: .};
			. as $write | any($responses[];
				.call <= $write.index and .task.id == $write.id
				and (.task.title | startswith("[ログイン] ") and endswith("（login:claude）"))
				and (.kind == "create" or (.task.project_id == $project and .task.creator_type == "agent"
					and .task.creator_id == $agent and $calls[.call - 1][2] == $write.id))))' \
		"$test_dir/calls.jsonl" >/dev/null
}

# 失敗する操作、最初の観測、次の観測、2 回目に起こる操作（get と一覧を除く）の順。
while IFS='|' read -r operation first next expected; do
	login_reset
	mkdir -p "$(dirname "$(login_state_file)")"
	touch "$test_dir/check-pairs"
	case $operation in
	create) echo '[ログイン] Claude Code のログイン' >"$test_dir/fail-create-prefix" ;;
	label | label-list) touch "$test_dir/fail-$operation" "$test_dir/check-saved-id" ;;
	done) login_prev_state warn; touch "$test_dir/fail-done" ;;
	*) login_prev_state warn; touch "$test_dir/fail-$operation" ;;
	esac
	observe_login "$first"
	rc=0
	login_run 'claude codex' || rc=$?
	[[ $rc == 1 ]]
	[[ $operation != label || -f $test_dir/saved-id-checked ]]
	# 1 回目: 失敗した操作より前の操作は済み、その行は決まった形で残る。
	first_creates=$(jq -s '[.[] | select(.kind == "create")] | length' "$test_dir/responses.jsonl")
	case $operation in
	create)
		[[ $(comment_count) == 0 ]]
		jq -e 'has("login:claude") | not' "$(login_state_file)" >/dev/null ;;
	label | label-list)
		[[ $(comment_count) == 0 && $first_creates == 1 ]]
		jq -e --arg level "$first" '."login:claude" == {level: $level, issue: env.TEST_ISSUE_ID, labeled: false}' "$(login_state_file)" >/dev/null ;;
	update)
		[[ $(comment_count) == 0 ]]
		jq -e '."login:claude" == {level: "warn", issue: env.TEST_LOGIN_ID, labeled: true}' "$(login_state_file)" >/dev/null ;;
	comment)
		[[ $(comment_count) == 0 ]]
		jq -e '."login:claude" == {level: "warn", issue: env.TEST_LOGIN_ID, labeled: true}' "$(login_state_file)" >/dev/null ;;
	done)
		[[ $(comment_count) == 1 ]]
		jq -e '."login:claude" == {level: "ok", issue: env.TEST_LOGIN_ID, labeled: true}' "$(login_state_file)" >/dev/null ;;
	esac
	jq -e '."login:codex" == {level: "ok"}' "$(login_state_file)" >/dev/null
	assert_verified_writes

	# 2 回目: 失敗を直し、次の観測で、行ごとに決まった操作だけが起こる。
	reset_server
	touch "$test_dir/check-pairs"
	echo "$login_title" >"$test_dir/get-title"
	observe_login "$next"
	login_run 'claude codex'
	actual=$(jq -rs '[.[] | select(.[0] == "issue" and .[1] != "get") | .[1]] | join(",")' "$test_dir/calls.jsonl")
	[[ $actual == "$expected" ]]
	case ,$expected, in
	*,comment,*) [[ $(comment_count) == 1 ]] ;;
	*) [[ $(comment_count) == 0 ]] ;;
	esac
	case ,$expected, in
	*,create,*) [[ $(jq -s '[.[] | select(.kind == "create")] | length' "$test_dir/responses.jsonl") == 1 && $first_creates == 0 ]] ;;
	esac
	assert_verified_writes
	id=$TEST_LOGIN_ID
	case $operation in create | label | label-list) id=$TEST_ISSUE_ID ;; esac
	case ,$expected, in
	*,update,*)
		case $next in warn) title='Claude Code のログインの期限'; sentence=$sentence_warn ;; error) title='Claude Code のログイン'; sentence=$sentence_error ;; unverified) title='Claude Code のログインを確認できない'; sentence=$sentence_unverified ;; esac
		jq -se --arg id "$id" --arg title "[ログイン] ${title}（login:claude）" --arg sentence "$sentence" \
			'length == 1 and (.[0] | .id == $id and .title == $title and (.description | startswith($sentence + "\n")))' "$test_dir/updates.jsonl" >/dev/null
		;;
	esac
	# 残りの操作（ラベル）があれば、同じ観測の次の実行が終え、そのあとは何も呼ばない。
	converged=false
	for _ in 1 2 3; do
		: >"$test_dir/calls.jsonl"
		login_run 'claude codex'
		if [[ ! -s $test_dir/calls.jsonl ]]; then converged=true; break; fi
	done
	[[ $converged == true ]]
	if [[ $next == ok ]]; then
		jq -e '."login:claude" == {level: "ok"}' "$(login_state_file)" >/dev/null
	else
		jq -e --arg level "$next" --arg id "$id" \
			'."login:claude" == {level: $level, issue: $id, labeled: true}' "$(login_state_file)" >/dev/null
	fi
	echo "PASS 失敗した操作のやり直し: $operation の失敗、$first から $next の観測"
done <<'CASES'
create|error|error|create,label
create|error|ok|
create|error|warn|create,label
label|error|error|label
label|error|ok|comment,status
label|error|warn|update,comment
label-list|error|error|label
label-list|error|ok|comment,status
label-list|error|warn|update,comment
update|error|error|update,comment
update|error|warn|
update|error|unverified|update,comment
comment|error|error|update,comment
comment|error|warn|
comment|ok|ok|comment,status
comment|ok|warn|
done|ok|ok|status
done|ok|warn|update,comment
done|ok|error|update,comment
CASES

# 観測が確定しない実行（使用量の取得に失敗、ログインが error）は、行の level のまま、残った done とラベルだけを続ける。
# ok への戻りも、level の書き換えもしない。旧形式（labeled のない行）は、付け終えたものとして読む。
unconfirmed_login() {
	case $1 in
	fetch-fail) echo 1 >"$test_dir/claude.status"; echo 'ログイン済みでも使えない' >"$test_dir/claude.json" ;;
	login-error) claude_auth 1 '{"loggedIn":false}' ;;
	esac
}
usage_title='[使用上限] Claude の Current session（claude:Current session）'
for how in fetch-fail login-error; do
	for shape in labeled legacy; do
		login_reset
		mkdir -p "$(dirname "$(login_state_file)")"
		jq -n --arg shape "$shape" '{"claude:Current session": ({level: "ok", issue: env.TEST_USAGE_ID} + (if $shape == "labeled" then {labeled: true} else {} end))}' >"$(login_state_file)"
		echo "$usage_title" >"$test_dir/get-title"
		unconfirmed_login "$how"
		login_run || true
		jq -se '[.[] | select(.[0:2] == ["issue", "status"])] == [["issue","status",env.TEST_USAGE_ID,"done","--no-start"]]
			and ([.[] | select(.[0:3] == ["issue", "label", "add"] and .[3] == env.TEST_USAGE_ID)] | length == 0)' "$test_dir/calls.jsonl" >/dev/null
		[[ $(comment_count) == 0 ]]
		jq -e '."claude:Current session" == {level: "ok"}' "$(login_state_file)" >/dev/null
		assert_no_leak
	done
	# done の失敗が残った行は、取得に失敗した実行でも、次の実行で done をやり直す。
	login_reset
	mkdir -p "$(dirname "$(login_state_file)")"
	jq -n '{"claude:Current session": {level: "ok", issue: env.TEST_USAGE_ID, labeled: true}}' >"$(login_state_file)"
	echo "$usage_title" >"$test_dir/get-title"
	unconfirmed_login "$how"
	touch "$test_dir/fail-done"
	if login_run; then exit 1; fi
	jq -e '."claude:Current session" == {level: "ok", issue: env.TEST_USAGE_ID, labeled: true}' "$(login_state_file)" >/dev/null
	echo "PASS 観測が確定しない実行: $how でも、残った done をやり直し、ok へ戻す書き換えはしない"

	for shape in labeled legacy; do
		# ラベルが残る行は、ラベルだけ付け直す。コメントも題の書き換えも done もしない。
		login_reset
		mkdir -p "$(dirname "$(login_state_file)")"
		if [[ $shape == labeled ]]; then
			jq -n '{"claude:Current session": {level: "warn", issue: env.TEST_USAGE_ID, labeled: false}}' >"$(login_state_file)"
		else
			jq -n '{"claude:Current session": {level: "warn", issue: env.TEST_USAGE_ID}}' >"$(login_state_file)"
		fi
		echo "$usage_title" >"$test_dir/get-title"
		unconfirmed_login "$how"
		login_run || true
		if [[ $shape == labeled ]]; then
			jq -se '[.[] | select(.[0:2] == ["issue", "get"])] == [["issue","get",env.TEST_USAGE_ID,"--output","json"]]
				and ([.[] | select(.[0:3] == ["issue", "label", "add"] and .[3] == env.TEST_USAGE_ID)] | length == 1)' "$test_dir/calls.jsonl" >/dev/null
			jq -e '."claude:Current session" == {level: "warn", issue: env.TEST_USAGE_ID, labeled: true}' "$(login_state_file)" >/dev/null
		else
			# 旧形式の行は付け終えたものとして読み、サーバーのタスクを読まず、書き込まない。
			jq -se '[.[] | select(index(env.TEST_USAGE_ID))] | length == 0' "$test_dir/calls.jsonl" >/dev/null
			jq -e '."claude:Current session" == {level: "warn", issue: env.TEST_USAGE_ID}' "$(login_state_file)" >/dev/null
		fi
		[[ $(comment_count) == 0 ]]
		jq -se '[.[] | select(.[0:2] == ["issue", "status"] or .[0:2] == ["issue", "update"])] | length == 0' "$test_dir/calls.jsonl" >/dev/null
		assert_no_leak
	done
	echo "PASS 観測が確定しない実行: $how でも、ラベルが残る行だけ付け直し、付け終えた行には何もしない"
done

# 使用上限のタスクの更新に失敗しても、あとのログインの行を処理してから 1 で終える。
login_reset
mkdir -p "$(dirname "$(login_state_file)")"
jq -n '{"claude:Current session": {level: "warn", issue: env.TEST_USAGE_ID, labeled: true}}' >"$(login_state_file)"
echo "$usage_title" >"$test_dir/get-title"
echo '{"is_error":false,"result":"Current session: 100% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
claude_auth 0 "$(expiry_json 3)"
touch "$test_dir/fail-comment"
if login_run; then exit 1; fi
[[ $(created_title) == '[ログイン] Claude Code のログインの期限（login:claude）' ]]
jq -e '."claude:Current session" == {level: "warn", issue: env.TEST_USAGE_ID, labeled: true}
	and ."login:claude" == {level: "warn", issue: env.TEST_ISSUE_ID, labeled: true}' "$(login_state_file)" >/dev/null
assert_no_leak
login_reset
echo 'PASS 更新の失敗: 使用上限のタスクを更新できなくても、ログインの行を処理してから失敗にする'

# 使用上限の起票だけが失敗しても、ログインと後続ランタイムを処理する。失敗した行は作らない。
login_reset
echo '[使用上限] Claude の Current session' >"$test_dir/fail-create-prefix"
echo '{"is_error":false,"result":"Current session: 100% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
claude_auth 0 "$(expiry_json 3)"
echo '{"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{"codex":{"primary":{"windowDurationMins":10080,"usedPercent":80,"resetsAt":604800},"secondary":null}}}}' >"$test_dir/codex.jsonl"
rc=0
login_run 'claude codex' || rc=$?
[[ $rc == 1 ]]
grep -qF 'mock create failure' "$test_dir/err"
jq -e '(has("claude:Current session") | not)
	and ."login:claude".level == "warn" and ."codex:codex:10080".level == "warn"
	and ."login:codex".level == "ok"' "$(login_state_file)" >/dev/null
jq -se '[.[] | select(.[0:2] == ["issue", "create"]) | .[3]] ==
	["[使用上限] Claude の Current session（claude:Current session）",
	 "[ログイン] Claude Code のログインの期限（login:claude）",
	 "[使用上限] Codex の codex の週の枠（codex:codex:10080）"]' "$test_dir/calls.jsonl" >/dev/null
echo 'PASS 起票の失敗: 失敗した行は作らず、ログインと後続ランタイムを更新する'

# 既存タスクを読めず時間切れになった行は、同じ実行で読み直さず前回の状態を残す。
login_reset
mkdir -p "$(dirname "$(login_state_file)")"
jq -n '{"claude:Current session": {level: "warn", issue: env.TEST_USAGE_ID, labeled: true}}' >"$(login_state_file)"
echo '{"is_error":false,"result":"Current session: 100% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
claude_auth 0 "$(expiry_json 3)"
touch "$test_dir/hang-get"
rc=0
login_run 'claude codex' USAGE_TASK_READ_SECONDS=2 || rc=$?
[[ $rc == 1 ]]
grep -qF 'サーバーから読めなかった' "$test_dir/err"
jq -se '[.[] | select(.[0:2] == ["issue", "get"])] == [["issue","get",env.TEST_USAGE_ID,"--output","json"]]' "$test_dir/calls.jsonl" >/dev/null
jq -e '."claude:Current session" == {level: "warn", issue: env.TEST_USAGE_ID, labeled: true}
	and ."login:claude".level == "warn" and ."login:codex".level == "ok"' "$(login_state_file)" >/dev/null
[[ $(comment_count) == 0 ]]
echo 'PASS 既存タスクの時間切れ: その行を保ち、ログインと後続ランタイムを更新する'

# ===== 前のバージョンのタスクと行 =====
legacy_state() { # キー
	mkdir -p "$(dirname "$(login_state_file)")"
	jq -n --arg k "$1" '{($k): {level: "warn", issue: env.TEST_LEGACY_ID}}' >"$(login_state_file)"
	printf '%s 流し直す前のタスク\n' "$(title_prefix "$1")" >"$test_dir/get-title"
}

# 題にキーのない前のバージョンのタスクは、観測が変わって書き込むときに状態から外し、閉じてよいタスクとして ID を書く。
# 外した行は、同じ実行では書き戻さず、次の実行が題にキーを付けて作り直す。
login_reset
legacy_state login:claude
observe_login error
rc=0
login_run 'claude codex' || rc=$?
[[ $rc == 1 ]]
grep -qxF "閉じてよいタスク: $TEST_LEGACY_ID" "$test_dir/err"
grep -qF '状態から外した' "$test_dir/err"
jq -se '[.[] | select(.[0:2] == ["issue", "get"])] == [["issue","get",env.TEST_LEGACY_ID,"--output","json"]]
	and ([.[] | select(.[0:2] == ["issue", "create"] or .[0:2] == ["issue", "update"] or .[0:2] == ["issue", "comment"] or .[0:2] == ["issue", "status"])] | length == 0)' "$test_dir/calls.jsonl" >/dev/null
jq -e 'has("login:claude") | not' "$(login_state_file)" >/dev/null
: >"$test_dir/calls.jsonl"
login_run 'claude codex'
[[ $(created_title) == '[ログイン] Claude Code のログイン（login:claude）' ]]
jq -e '."login:claude" == {level: "error", issue: env.TEST_ISSUE_ID, labeled: true}' "$(login_state_file)" >/dev/null
echo 'PASS 前のバージョンのタスク: 観測が変わると外して閉じてよい ID を書き、次の実行で作り直す'

# 観測が行の level と同じなら、前のバージョンの行には何も呼ばない（タスクを読まず、書かない）。
login_reset
legacy_state login:claude
observe_login warn
login_run 'claude codex'
jq -se '[.[] | select(index(env.TEST_LEGACY_ID))] | length == 0' "$test_dir/calls.jsonl" >/dev/null
[[ $(comment_count) == 0 ]]
jq -e '."login:claude" == {level: "warn", issue: env.TEST_LEGACY_ID}' "$(login_state_file)" >/dev/null
echo 'PASS 前のバージョンの行: 観測が同じなら、タスクを読まず、書き込まない'

# 題にキーのある前のバージョンの行は、一度読んで書き換え、level と ID の形のまま level を進める。
login_reset
mkdir -p "$(dirname "$(login_state_file)")"
jq -n '{"claude:Current session": {level: "warn", issue: env.TEST_LEGACY_ID}}' >"$(login_state_file)"
echo "$usage_title" >"$test_dir/get-title"
echo '{"is_error":false,"result":"Current session: 100% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
login_run
jq -se '[.[] | select(.[0:2] == ["issue", "get"])] == [["issue","get",env.TEST_LEGACY_ID,"--output","json"]]' "$test_dir/calls.jsonl" >/dev/null
[[ $(comment_count) == 1 ]]
jq -e '."claude:Current session" == {level: "limited", issue: env.TEST_LEGACY_ID}' "$(login_state_file)" >/dev/null
# 付け終えたものとして読むので、次に ok へ戻るときもラベルを付けず、done にする。
: >"$test_dir/calls.jsonl"
echo "$usage_zero" >"$test_dir/claude.json"
login_run
jq -se '([.[] | select(.[0:3] == ["issue", "label", "add"])] | length == 0)
	and ([.[] | select(.[0:2] == ["issue", "status"])] == [["issue","status",env.TEST_LEGACY_ID,"done","--no-start"]])' "$test_dir/calls.jsonl" >/dev/null
jq -e '."claude:Current session" == {level: "ok"}' "$(login_state_file)" >/dev/null
echo 'PASS 前のバージョンの行: キーのあるタスクは一度読んで更新し、ラベルを付け終えたものとして ok に戻す'

# ===== 状態のファイルの行の形 =====
# 形の合わない行は、起動時に状態から外し、タスクには書き込まない。形の合う行は、そのまま使う。
login_reset
mkdir -p "$(dirname "$(login_state_file)")"
jq -n '{"login:claude": {level: "warn", issue: env.TEST_LOGIN_ID, labeled: true},
	("codex:改行" + "\n"): {level: "warn", issue: env.TEST_OTHER_ID},
	"foo:未知の始まり": {level: "warn", issue: env.TEST_OTHER_ID},
	"claude:ID が UUID でない": {level: "warn", issue: "invalid"},
	"claude:ID に改行": {level: "warn", issue: (env.TEST_OTHER_ID + "\n")},
	"claude:状態が未知": {level: "bogus", issue: env.TEST_OTHER_ID},
	"claude:labeled が真偽でない": {level: "warn", issue: env.TEST_OTHER_ID, labeled: "yes"},
	"claude:余分な欄": {level: "warn", issue: env.TEST_OTHER_ID, pending: {op: "comment"}},
	"claude:行が文字列": "warn"}' >"$(login_state_file)"
observe_login warn
rc=0
login_run 'claude codex' || rc=$?
[[ $rc == 1 ]]
[[ $(grep -c '形が合わない。状態から外した' "$test_dir/err") == 8 ]]
jq -e 'keys == ["login:claude", "login:codex"] and ."login:claude" == {level: "warn", issue: env.TEST_LOGIN_ID, labeled: true}' "$(login_state_file)" >/dev/null
[[ ! -s $test_dir/calls.jsonl ]]
echo 'PASS 行の形: 形の合わない行は起動時に外して失敗にし、タスクには書き込まず、形の合う行は使う'

# 観測が確定しない実行は、行の数によらず jq を同じ数（1 回）だけ起こす。
jq_count_file=$test_dir/jq-count
count_unconfirmed_jq() { # 行の数
	local rows=$1
	: >"$jq_count_file"
	jq -nc --argjson n "$rows" '[range($n) | {key: "claude:枠 \(.)", value: {level: "warn", issue: env.TEST_ISSUE_ID, labeled: true}}] | from_entries' >"$test_dir/startup-state.json"
	state=$(cat "$test_dir/startup-state.json")
	jq() { echo x >>"$jq_count_file"; command jq "$@"; }
	continue_tool_rows claude
	unset -f jq
	wc -l <"$jq_count_file" | tr -d ' '
}
one=$(count_unconfirmed_jq 1)
many=$(count_unconfirmed_jq 500)
[[ $one == "$many" && $one == 1 ]]
echo 'PASS 観測が確定しない実行: 処理済みの行が 1 行でも 500 行でも、jq の起動は同じ数（1 回）'
