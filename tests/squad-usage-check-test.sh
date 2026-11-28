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
label_failed=false
USAGE_WARN_PERCENT=80

# 読み取りだけを偽物にし、行のキー・状態・表示を現行の出力に固定する。
mkdir -p "$test_dir/bin"
export USAGE_TEST_DIR=$test_dir
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

create_default=$(python3 "$root/tests/multica-fixture.py" "$test_dir" base issue-create | jq '.id = "test-issue"')
label_default=$(python3 "$root/tests/multica-fixture.py" "$test_dir" base label-list | jq '[.id = "operations-label" | .name = "運用"]')
get_default=$(python3 "$root/tests/multica-fixture.py" "$test_dir" base issue-get)
export create_default label_default get_default
# 見張りがタスクを更新する前に読むサーバーのタスク。既定は、この見張りが同じプロジェクトに、指定の題で作ったもの。
# get-title に題を、get-override.json に差し替える欄を置く。
export MULTICA_AGENT_ID=test-agent
multica() {
	if [[ "$*" == version ]]; then echo 'multica fixture-version'; return; fi
	python3 "$USAGE_FIXTURE_ROOT/tests/cli-stub.py" none "$test_dir" multica calls.jsonl record -- "$@"
	case "$1 $2" in
	'issue create')
		if [[ -f $test_dir/fail-create-prefix && $4 == "$(cat "$test_dir/fail-create-prefix")"* ]]; then
			echo 'mock create failure' >&2
			return 1
		fi
		local file
		while (($#)); do
			if [[ $1 == --description-file ]]; then file=$2; break; fi
			shift
		done
		cat "$file" >"$test_dir/description.md"
		if [[ -f $test_dir/create-response.json ]]; then
			cat "$test_dir/create-response.json"
		else
			echo "$create_default"
		fi
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
		jq --arg id "$3" --arg project "$USAGE_CHECK_PROJECT" --arg agent "${MULTICA_AGENT_ID-}" --arg title "$(cat "$test_dir/get-title")" \
			'.id = $id | .project_id = $project | .creator_type = "agent" | .creator_id = $agent | .title = $title' <<<"$get_default" |
			jq --slurpfile o <(if [[ -f $test_dir/get-override.json ]]; then cat "$test_dir/get-override.json"; else echo '{}'; fi) '. + $o[0]'
		;;
	'issue update')
		if [[ -f $test_dir/fail-update ]]; then echo 'mock update failure' >&2; return 1; fi
		local title file
		while (($#)); do
			case $1 in
			--title) title=$2 ;;
			--description-file) file=$2 ;;
			esac
			shift
		done
		jq -n --arg t "$title" --rawfile d "$file" '{title: $t, description: $d}' >>"$test_dir/updates.jsonl"
		;;
	'issue status') test "$4" == done ;;
	'label list')
		if [[ -f $test_dir/label-response.json ]]; then cat "$test_dir/label-response.json"; else
			echo "$label_default"
		fi ;;
	'issue label') test "$3 $4 $5" = 'add test-issue operations-label' ;;
	*) echo "Unexpected mock call: $*" >&2; return 1 ;;
	esac
}

# 読み取りの時間切れは Python から CLI を起動するので、同じモックを実行ファイルとしても置く。
export test_dir USAGE_CHECK_PROJECT
{
	printf '#!/usr/bin/env bash\n'
	declare -f multica
	printf 'multica "$@"\n'
} >"$test_dir/bin/multica"
chmod +x "$test_dir/bin/multica"

# 警告・使用上限到達・取得エラーのどの場合も、作成時点でプロジェクトを渡す。
for level in warn limited error; do
	state='{}'
	: >"$test_dir/calls.jsonl"
	apply test-key "$level" 'テスト枠' '詳細'
	jq -se --arg project "$USAGE_CHECK_PROJECT" --arg assignee "$USAGE_CHECK_ASSIGNEE" '
		def value($flag): . as $args | index($flag) as $i | $args[$i + 1];
		[.[] | select(.[0:2] == ["issue", "create"])] as $creates
		| ($creates | length) == 1
		and ($creates[0] | value("--project") == $project and value("--assignee") == $assignee)
		and ([.[] | select(.[0:3] == ["issue", "label", "add"])] | length) == 1
	' "$test_dir/calls.jsonl" >/dev/null
	jq -e --arg level "$level" '."test-key" == {level: $level, issue: "test-issue", keyed: true}' "$STATE_FILE" >/dev/null
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
	jq -e '. == {"claude:Current session": {level: "warn", issue: "test-issue", keyed: true},
		"codex:codex:10080": {level: "warn", issue: "test-issue", keyed: true},
		"login:claude": {level: "ok", issue: ""},
		"login:codex": {level: "ok", issue: ""}}' "$state_file" >/dev/null
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
	jq -e '."claude:Current session".level == "warn"' "$state_file" >/dev/null
	[[ ! -s $test_dir/comments.jsonl ]]
	rm "$test_dir/fail-comment"
	(cd "$test_dir" && bash "$script")
	(cd "$test_dir" && bash "$script")
	jq -se 'length == 1 and (.[0].body | contains("使用上限に達した"))' "$test_dir/comments.jsonl" >/dev/null
	jq -e '."claude:Current session".level == "limited"' "$state_file" >/dev/null
	echo '{"is_error":false,"result":"Current session: 0% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
	(cd "$test_dir" && bash "$script")
	jq -e '."claude:Current session" == {level:"ok",issue:""}' "$state_file" >/dev/null
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
	for tool in bash dirname mkdir mktemp jq python3 cat rm head seq grep cut date sleep; do
		ln -s "$(command -v "$tool")" "$selected_bin/$tool"
	done
	ln -s "$test_dir/bin/multica" "$selected_bin/multica"
	ln -s "$test_dir/bin/$selected" "$selected_bin/$selected"
	if [[ $selected == claude ]]; then disabled_key='codex:allowed'; else disabled_key='claude:Current session'; fi
	state_file=$(usage_check_state_path)
	mkdir -p "${state_file%/*}"
	jq -n --arg key "$disabled_key" '{($key):{level:"warn",issue: "disabled-issue", keyed: true}}' >"$state_file"
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
	jq -e --arg key "$disabled_key" '.[$key]=={level:"warn",issue: "disabled-issue", keyed: true}' "$state_file" >/dev/null
	: >"$test_dir/calls.jsonl"
	PATH="$selected_bin" /bin/bash "$script"
	[[ ! -s $test_dir/calls.jsonl ]]
	echo '{"is_error":false,"result":"Current session: 0% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
	echo '{"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{}}}' >"$test_dir/codex.jsonl"
	: >"$test_dir/comments.jsonl"
	PATH="$selected_bin" /bin/bash "$script"
	jq -e --arg key "$disabled_key" '.[$key]=={level:"warn",issue: "disabled-issue", keyed: true} and all(to_entries[]|select(.key!=$key); .value.level=="ok" and .value.issue=="")' "$state_file" >/dev/null
	jq -se '[.[]|select(.[0:2]==["issue","status"])]==[["issue","status","test-issue","done","--no-start"]]' "$test_dir/calls.jsonl" >/dev/null
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

# 書き込みは済んでいても応答が欠けていれば止まり、同じ実行で起票し直さない。
for field in id identifier; do
	state='{}'
	: >"$test_dir/calls.jsonl"
	python3 "$root/tests/multica-fixture.py" "$test_dir" base issue-create |
		jq --arg field "$field" 'del(.[$field])' >"$test_dir/create-response.json"
	if apply test-key warn 'テスト枠' '詳細' >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	grep -qF "issue-create の $field" "$test_dir/err"
	[[ $state == '{}' ]]
	jq -se 'length==1 and .[0][0:2]==["issue","create"]' "$test_dir/calls.jsonl" >/dev/null
done
rm "$test_dir/create-response.json"
echo 'PASS 起票応答: id・identifier の欠落で状態を進めず、起票は一度だけ'

for field in id name resource_type; do
	state='{}'; label_failed=false
	: >"$test_dir/calls.jsonl"
	python3 "$root/tests/multica-fixture.py" "$test_dir" base label-list |
		jq --arg field "$field" '[del(.[$field])]' >"$test_dir/label-response.json"
	apply test-key warn 'テスト枠' '詳細' >"$test_dir/out" 2>"$test_dir/err"
	grep -qF "label-list の $field" "$test_dir/err"
	[[ $label_failed == true ]]
	jq -se '[.[]|select(.[0:3]==["issue","label","add"])]|length==0' "$test_dir/calls.jsonl" >/dev/null
done
rm "$test_dir/label-response.json"
echo 'PASS ラベル応答: 必須欄の欠落は欄名で失敗し、ラベルを付けず起票済みの状態を保存する'

# 作るタスクの題は、キーの種類の始めで始まり、全角の括弧で囲んだキーで終わる。
task_failed=false
created_title() {
	jq -rs '[.[] | select(.[0:2] == ["issue", "create"])][0] | .[index("--title") + 1]' "$test_dir/calls.jsonl"
}
for case_ in 'test-key|テスト枠|[使用上限] テスト枠（test-key）' \
	'claude:fetch|Claude の使用量を取れない|[使用上限] Claude の使用量を取れない（claude:fetch）' \
	'codex:codex:300|Codex の codex の5 時間の枠|[使用上限] Codex の codex の5 時間の枠（codex:codex:300）' \
	'login:claude|Claude Code のログイン|[ログイン] Claude Code のログイン（login:claude）'; do
	IFS='|' read -r key title expected <<<"$case_"
	state='{}'
	: >"$test_dir/calls.jsonl"
	apply "$key" error "$title" '詳細'
	[[ $(created_title) == "$expected" ]]
	jq -e --arg k "$key" '.[$k] == {level: "error", issue: "test-issue", keyed: true}' "$STATE_FILE" >/dev/null
done
echo 'PASS 題のキー: 作るタスクの題が、キーの種類の始めで始まり、全角の括弧で囲んだキーで終わる'

# 更新する前のタスクの確認。合うタスクは、コメントも done もできる。
comment_count() { [[ -f $test_dir/comments.jsonl ]] && jq -s 'length' "$test_dir/comments.jsonl" || echo 0; }
reset_server() {
	rm -f "$test_dir/get-override.json" "$test_dir/fail-get" "$test_dir/hang-get" \
		"$test_dir/fail-update" "$test_dir/fail-comment" "$test_dir/fail-create-prefix"
	: >"$test_dir/calls.jsonl"
	: >"$test_dir/comments.jsonl"
	: >"$test_dir/updates.jsonl"
	task_failed=false
	legacy_checks='{}'
}
reset_server
echo '[使用上限] テスト枠（test-key）' >"$test_dir/get-title"
state='{"test-key":{"level":"warn","issue":"test-issue"}}'
apply test-key ok 'テスト枠' '詳細' 2>"$test_dir/err"
[[ $task_failed == false && $(comment_count) == 1 && ! -s $test_dir/err ]]
jq -se '[.[] | select(.[0:2] == ["issue", "get"])] == [["issue","get","test-issue","--output","json"]]
	and [.[] | select(.[0:2] == ["issue", "status"])] == [["issue","status","test-issue","done","--no-start"]]' "$test_dir/calls.jsonl" >/dev/null
echo 'PASS 更新の前の確認: 合うタスクは、サーバーのタスクを読んだうえでコメントし done にする'

# プロジェクト・作者・題の始め・題の終わりのキーのどれかが違えば、コメントも done もせず、状態から外して 1 で終える。
mismatch_case() { # 名前 キー 題 差し替えの JSON 新しい状態
	local name=$1 key=$2 title=$3 override=$4 level=$5
	reset_server
	echo "$title" >"$test_dir/get-title"
	echo "$override" >"$test_dir/get-override.json"
	state=$(jq -n --arg k "$key" '{($k): {level: "warn", issue: "test-issue", keyed: true}, other: {level: "warn", issue: "other-issue", keyed: true}}')
	apply "$key" "$level" '枠' '詳細' 2>"$test_dir/err"
	if [[ $task_failed != true || $(comment_count) != 0 ]]; then echo "FAIL $name: 更新したか、失敗にしていない" >&2; exit 1; fi
	jq -se '[.[] | select(.[0:2] == ["issue", "status"] or .[0:2] == ["issue", "comment"])] | length == 0' "$test_dir/calls.jsonl" >/dev/null
	jq -e --arg k "$key" 'has($k) | not' <<<"$state" >/dev/null
	jq -e '.other == {level: "warn", issue: "other-issue", keyed: true}' <<<"$state" >/dev/null
	jq -e --arg k "$key" 'has($k) | not' "$STATE_FILE" >/dev/null
	grep -qF "状態から外した" "$test_dir/err"
	echo "PASS 更新の前の確認: $name は更新せず、状態から外して失敗にする"
}
for level in limited ok; do
	t='[使用上限] 枠（test-key）'
	mismatch_case "別のプロジェクト（${level}）" test-key "$t" '{"project_id":"other-project"}' "$level"
	mismatch_case "人の作者（${level}）" test-key "$t" '{"creator_type":"member"}' "$level"
	mismatch_case "別のエージェントの作者（${level}）" test-key "$t" '{"creator_id":"other-agent"}' "$level"
	mismatch_case "題の始めが違う（${level}）" test-key '人が書き換えた題（test-key）' '{}' "$level"
	mismatch_case "題の始めの空白がない（${level}）" test-key '[使用上限]枠（test-key）' '{}' "$level"
	mismatch_case "題が空（${level}）" test-key '' '{"title":null}' "$level"
	mismatch_case "キーが題の終わりにない（${level}）" test-key '[使用上限] 枠（test-key）メモ' '{}' "$level"
	mismatch_case "キーの括弧が半角（${level}）" test-key '[使用上限] 枠(test-key)' '{}' "$level"
	# 同じ見張りが同じプロジェクトに作った、別のキーのタスクを更新しない。
	mismatch_case "キーが fetch と枠で違う（${level}）" claude:fetch '[使用上限] Claude の Current session（claude:Current session）' '{}' "$level"
	mismatch_case "キーが枠と fetch で違う（${level}）" 'claude:Current session' '[使用上限] Claude の使用量を取れない（claude:fetch）' '{}' "$level"
	mismatch_case "キーが枠どうしで違う（${level}）" 'codex:codex:300' '[使用上限] Codex の codex の週の枠（codex:codex:10080）' '{}' "$level"
	mismatch_case "login:claude に login:codex のタスク（${level}）" login:claude '[ログイン] Codex のログイン（login:codex）' '{}' "$level"
	mismatch_case "login:codex に login:claude のタスク（${level}）" login:codex '[ログイン] Claude Code のログイン（login:claude）' '{}' "$level"
	mismatch_case "ログインのキーに使用上限の題（${level}）" login:claude '[使用上限] 枠（login:claude）' '{}' "$level"
	mismatch_case "使用上限のキーにログインの題（${level}）" test-key '[ログイン] 枠（test-key）' '{}' "$level"
done
# 自分の ID が分からなければ、作者を確認できないので合わない。
(
	unset MULTICA_AGENT_ID
	reset_server
	echo '[使用上限] 枠（test-key）' >"$test_dir/get-title"
	echo '{"creator_id":""}' >"$test_dir/get-override.json"
	state='{"test-key":{"level":"warn","issue":"test-issue"}}'
	apply test-key limited '枠' '詳細' 2>"$test_dir/err"
	[[ $task_failed == true && $(comment_count) == 0 ]]
)
echo 'PASS 更新の前の確認: MULTICA_AGENT_ID がなければ作者が合わず、更新しない'

# サーバーのタスクを読めなければ、状態を変えず、更新せずに失敗する（外した扱いにもしない）。
reset_server
touch "$test_dir/fail-get"
state='{"test-key":{"level":"warn","issue":"test-issue"}}'
state_before=$state
apply test-key limited '枠' '詳細' >"$test_dir/out" 2>"$test_dir/err"
rm "$test_dir/fail-get"
grep -qF 'サーバーから読めなかった' "$test_dir/err"
[[ $state == "$state_before" && $task_failed == true && $(comment_count) == 0 ]]
echo 'PASS 更新の前の確認: タスクを読めないときは、状態を変えず更新もせず、失敗にして次の行へ進む'

# ok でない状態どうしの変化は、新しい状態の始めの文をコメントする。
transition_case() { # キー 題 前の状態 新しい状態 コメントの始めの文
	local key=$1 title=$2 prev=$3 level=$4 sentence=$5
	reset_server
	echo "$title" >"$test_dir/get-title"
	state=$(jq -n --arg k "$key" --arg l "$prev" '{($k): {level: $l, issue: "test-issue", keyed: true}}')
	apply "$key" "$level" '枠' '詳細の文' 2>"$test_dir/err"
	[[ $task_failed == false && ! -s $test_dir/err ]]
	jq -se --arg t "$(title_prefix "$key") 枠（${key}）" --arg s "$sentence" \
		'length == 1 and .[0].title == $t and (.[0].description | startswith($s + "\n\n詳細の文\n"))' "$test_dir/updates.jsonl" >/dev/null
	jq -se --arg s "$sentence" 'length == 1 and (.[0].body | startswith($s + "。\n\n") and contains("詳細の文"))' "$test_dir/comments.jsonl" >/dev/null
	jq -se '[.[] | select(.[0:2] == ["issue", "status"])] | length == 0' "$test_dir/calls.jsonl" >/dev/null
	jq -e --arg k "$key" --arg l "$level" '.[$k] == {level: $l, issue: "test-issue", keyed: true}' <<<"$state" >/dev/null
	echo "PASS 状態の変化: $key の $prev から $level で、新しい状態の文をコメントする"
}
t='[使用上限] 枠（test-key）'
transition_case test-key "$t" warn error '使用量を取れなくなり、見張れていない。ログインや表示の形が変わっていないか確認する'
transition_case test-key "$t" error warn '使用上限が近い。重い作業の割り振りを控えるか、エージェントを別の系統のモデルに寄せる'
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
	jq -n '{"claude:Current session": {level: "warn", issue: "test-issue", keyed: true}}' >"$state_file"
	echo '{"is_error":false,"result":"Current session: 100% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
	if (cd "$test_dir" && bash "$script") >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	grep -qF '状態から外した' "$test_dir/err"
	[[ $(comment_count) == 0 ]]
	jq -e 'has("claude:Current session") | not' "$state_file" >/dev/null
	jq -se '[.[] | select(.[0:2] == ["issue", "status"] or .[0:2] == ["issue", "comment"])] | length == 0' "$test_dir/calls.jsonl" >/dev/null
	# 次の実行は、外れたキーを新しい題（キー付き）で作り直す。
	: >"$test_dir/calls.jsonl"
	rm "$test_dir/get-override.json"
	(cd "$test_dir" && bash "$script")
	[[ $(created_title) == '[使用上限] Claude の Current session（claude:Current session）' ]]
	jq -e '."claude:Current session".level == "limited"' "$state_file" >/dev/null
)
echo 'PASS 本体: 合わないタスクを更新せず、状態から外して 1 で終え、次の実行で題にキーを付けて作り直す'

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
	jq -e --arg key "login:$1" '.[$key] == {level: "ok", issue: ""}' "$(login_state_file)" >/dev/null
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
		jq -e --arg l "$level" '."login:claude" == {level: $l, issue: "test-issue", keyed: true}' "$(login_state_file)" >/dev/null
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
	jq -n --arg l "$1" '{"login:claude": {level: $l, issue: "login-issue", keyed: true}}' >"$(login_state_file)"
	echo "$login_title" >"$test_dir/get-title"
}
for prev in warn error unverified; do
	# 同じ実行で使用量を読めれば、「ログインし直された」とコメントして done にする。
	login_reset
	mkdir -p "$(dirname "$(login_state_file)")"
	login_prev_state "$prev"
	login_run
	jq -se 'length == 1 and (.[0].body | startswith("ログインし直された。\n\n"))' "$test_dir/comments.jsonl" >/dev/null
	jq -se '[.[] | select(.[0:2] == ["issue", "status"])] == [["issue","status","login-issue","done","--no-start"]]' "$test_dir/calls.jsonl" >/dev/null
	jq -e '."login:claude" == {level: "ok", issue: ""}' "$(login_state_file)" >/dev/null
	grep -qx claude "$test_dir/runtime-calls"
	assert_no_leak

	# 使用量を読めなければ、前回の状態のまま、コメントも done もしない。
	login_reset
	mkdir -p "$(dirname "$(login_state_file)")"
	login_prev_state "$prev"
	echo 1 >"$test_dir/claude.status"; echo 'ログイン済みでも使えない' >"$test_dir/claude.json"
	login_run
	jq -e --arg l "$prev" '."login:claude" == {level: $l, issue: "login-issue", keyed: true}' "$(login_state_file)" >/dev/null
	[[ $(comment_count) == 0 ]]
	jq -se '[.[] | select(.[0:2] == ["issue", "status"] or .[0:2] == ["issue", "comment"])] | length == 0' "$test_dir/calls.jsonl" >/dev/null
	grep -qx claude "$test_dir/runtime-calls"
	assert_no_leak
	echo "PASS ログインの戻り: ${prev} から、使用量を読めたときだけ ok に戻し、読めなければ前回のまま"
done

# error のツールは使用率を読まず、使用上限の行を前回のままにする。確認失敗のツールは使用率を読む。
login_reset
mkdir -p "$(dirname "$(login_state_file)")"
jq -n '{"login:claude": {level: "error", issue: "login-issue", keyed: true}, "claude:Current session": {level: "warn", issue: "usage-issue", keyed: true}}' >"$(login_state_file)"
echo "$login_title" >"$test_dir/get-title"
claude_auth 1 '{"loggedIn":false,"email":"fake.person@example.invalid"}'
login_run
[[ ! -s $test_dir/runtime-calls ]]
jq -e '. == {"login:claude": {level: "error", issue: "login-issue", keyed: true}, "claude:Current session": {level: "warn", issue: "usage-issue", keyed: true}}' "$(login_state_file)" >/dev/null
[[ $(comment_count) == 0 ]]
jq -se '[.[] | select(.[0:2] == ["issue", "status"] or .[0:2] == ["issue", "comment"] or .[0:2] == ["issue", "create"])] | length == 0' "$test_dir/calls.jsonl" >/dev/null
assert_no_leak
login_reset
mkdir -p "$(dirname "$(login_state_file)")"
jq -n '{"claude:Current session": {level: "warn", issue: "usage-issue", keyed: true}}' >"$(login_state_file)"
echo '[使用上限] Claude の Current session（claude:Current session）' >"$test_dir/get-title"
claude_auth 2 "$logged_in"
login_run
grep -qx claude "$test_dir/runtime-calls"
jq -e '."claude:Current session" == {level: "ok", issue: ""} and ."login:claude".level == "unverified"' "$(login_state_file)" >/dev/null
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
	jq -e --arg level "$level" '."login:codex" == {level: $level, issue: "test-issue", keyed: true}' "$(login_state_file)" >/dev/null
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
	jq -n --arg level "$prev" '{"login:codex": {level: $level, issue: "login-issue", keyed: true}, "codex:allowed": {level: "warn", issue: "usage-issue", keyed: true}}' >"$(login_state_file)"
	echo "$codex_login_title" >"$test_dir/get-title"
	if [[ $prev == error ]]; then
		codex_login 1 'Not logged in'
		login_run codex
		[[ ! -s $test_dir/runtime-calls && ! -s $test_dir/calls.jsonl ]]
		jq -e '."codex:allowed" == {level: "warn", issue: "usage-issue", keyed: true}' "$(login_state_file)" >/dev/null
	fi
	# 使用量の行を初期化し、ログインの復旧を読む。
	jq -n --arg level "$prev" '{"login:codex": {level: $level, issue: "login-issue", keyed: true}}' >"$(login_state_file)"
	codex_login 0 'fake.person@example.invalid'
	cp "$test_dir/codex.jsonl" "$test_dir/codex-ok.jsonl"
	echo '{"id":2,"error":{"message":"ログインが必要"}}' >"$test_dir/codex.jsonl"
	login_run 'claude codex'
	[[ $(cat "$test_dir/runtime-calls") == $'claude\ncodex' ]]
	jq -e --arg level "$prev" '."login:codex" == {level: $level, issue: "login-issue", keyed: true} and ."codex:fetch".level == "error"' "$(login_state_file)" >/dev/null
	jq -se 'all(.[]; .[0:2] != ["issue", "comment"] and .[0:2] != ["issue", "status"])' "$test_dir/calls.jsonl" >/dev/null
	assert_no_leak
	reset_server
	mv "$test_dir/codex-ok.jsonl" "$test_dir/codex.jsonl"
	# 使用量の取得エラーのタスクは別キー。ログインの更新だけを確認する。
	jq -n --arg level "$prev" '{"login:codex": {level: $level, issue: "login-issue", keyed: true}}' >"$(login_state_file)"
	echo "$codex_login_title" >"$test_dir/get-title"
	login_run codex
	jq -e '."login:codex" == {level: "ok", issue: ""}' "$(login_state_file)" >/dev/null
	jq -se 'length == 1 and (.[0].body | startswith("ログインし直された。\n\n"))' "$test_dir/comments.jsonl" >/dev/null
	jq -se '[.[] | select(.[0:2] == ["issue", "status"])] == [["issue","status","login-issue","done","--no-start"]]' "$test_dir/calls.jsonl" >/dev/null
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

# ok でない状態どうしの変化は、題と本文を書き換える。limited から warn でも書き換え、書き換えに失敗してもコメントと状態の記録は続けて 1 で終える。
reset_server
echo '[使用上限] 枠（test-key）' >"$test_dir/get-title"
state='{"test-key":{"level":"limited","issue":"test-issue","keyed":true}}'
apply test-key warn '枠' '詳細の文' 2>"$test_dir/err"
jq -se '.[0].title == "[使用上限] 枠（test-key）" and (.[0].description | startswith("使用上限が近い。"))' "$test_dir/updates.jsonl" >/dev/null
jq -se 'length == 1 and (.[0].body | startswith("戻った。"))' "$test_dir/comments.jsonl" >/dev/null
echo 'PASS 題と本文の書き換え: limited から warn でも書き換え、「戻った」をコメントする'
reset_server
touch "$test_dir/fail-update"
state='{"test-key":{"level":"warn","issue":"test-issue","keyed":true}}'
apply test-key error '枠' '詳細の文' 2>"$test_dir/err"
grep -qF '書き換えられなかった' "$test_dir/err"
[[ $task_failed == true && $(comment_count) == 1 ]]
jq -e '."test-key" == {level: "error", issue: "test-issue", keyed: true, retitle: true}' <<<"$state" >/dev/null
reset_server
echo 'PASS 題と本文の書き換え: 失敗してもコメントと状態の記録は続け、実行の結果を失敗にする'

# 印 keyed のない行のタスクは、状態が変わらなくても確認する。合えば印を付け、合わなければ外す。印のある行は確認しない。
reset_server
echo '[使用上限] 枠（test-key）' >"$test_dir/get-title"
state='{"test-key":{"level":"warn","issue":"test-issue"}}'
reconcile_legacy_tasks
apply test-key warn '枠' '詳細'
jq -e '."test-key" == {level: "warn", issue: "test-issue", keyed: true}' <<<"$state" >/dev/null
[[ $task_failed == false && $(comment_count) == 0 ]]
reset_server
echo '流し直す前の題' >"$test_dir/get-title"
state='{"test-key":{"level":"warn","issue":"test-issue"}}'
reconcile_legacy_tasks 2>"$test_dir/err"
jq -e 'has("test-key") | not' <<<"$state" >/dev/null
[[ $task_failed == true ]]
reset_server
state='{"test-key":{"level":"warn","issue":"test-issue","keyed":true}}'
reconcile_legacy_tasks
apply test-key warn '枠' '詳細'
jq -se '[.[] | select(.[0:2] == ["issue", "get"])] | length == 0' "$test_dir/calls.jsonl" >/dev/null
reset_server
echo 'PASS 印 keyed: 印のない行は状態が同じでも確認して印を付け、合わなければ外し、印のある行は確認しない'

# 使用上限のタスクの更新に失敗しても、あとのログインの行を処理してから 1 で終える。
login_reset
mkdir -p "$(dirname "$(login_state_file)")"
jq -n '{"claude:Current session": {level: "warn", issue: "usage-issue", keyed: true}}' >"$(login_state_file)"
echo '[使用上限] Claude の Current session（claude:Current session）' >"$test_dir/get-title"
echo '{"is_error":false,"result":"Current session: 100% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
claude_auth 0 "$(expiry_json 3)"
touch "$test_dir/fail-comment"
if login_run; then exit 1; fi
[[ $(created_title) == '[ログイン] Claude Code のログインの期限（login:claude）' ]]
jq -e '."claude:Current session" == {level: "warn", issue: "usage-issue", keyed: true}
	and ."login:claude" == {level: "warn", issue: "test-issue", keyed: true}' "$(login_state_file)" >/dev/null
assert_no_leak
login_reset
echo 'PASS 更新の失敗: 使用上限のタスクを更新できなくても、ログインの行を処理してから失敗にする'

# 見張り全体で、状態を読めない行や見張らないランタイムの行も照合する。
legacy_state() {
	mkdir -p "$(dirname "$(login_state_file)")"
	jq -n --arg k "$1" '{($k): {level: "warn", issue: "legacy-issue"}}' >"$(login_state_file)"
	printf '%s 流し直す前のタスク\n' "$(title_prefix "$1")" >"$test_dir/get-title"
}
assert_legacy_read_once() {
	jq -se '[.[] | select(.[0:2] == ["issue", "get"])] == [["issue","get","legacy-issue","--output","json"]]' \
		"$test_dir/calls.jsonl" >/dev/null
}
assert_legacy_removed() {
	local key=$1 runtimes=$2 rc=0
	login_run "$runtimes" || rc=$?
	[[ $rc == 1 ]] || return 1
	assert_legacy_read_once || return 1
	jq -e --arg k "$key" 'has($k) | not' "$(login_state_file)" >/dev/null || return 1
	grep -qF '状態から外した' "$test_dir/err"
}

legacy_failures=0
for legacy_case in fetch-error logged-out login-recovery unwatched; do
	login_reset
	legacy_key='claude:Current session'
	runtimes=claude
	case $legacy_case in
	fetch-error)
		echo 1 >"$test_dir/claude.status"
		;;
	logged-out)
		claude_auth 1 '{"loggedIn":false}'
		;;
	login-recovery)
		legacy_key=login:claude
		echo 1 >"$test_dir/claude.status"
		;;
	unwatched)
		runtimes=codex
		;;
	esac
	legacy_state "$legacy_key"
	if assert_legacy_removed "$legacy_key" "$runtimes"; then
		echo "PASS 旧タスクの照合: $legacy_case でも一度だけ読み、行ごと外す"
	else
		echo "FAIL 旧タスクの照合: $legacy_case で一度だけ読み、行ごと外すはず" >&2
		legacy_failures=$((legacy_failures + 1))
	fi
done
[[ $legacy_failures == 0 ]]

# 最初の照合で合った旧タスクは、同じ実行で状態が変わっても読み直さない。
login_reset
legacy_state 'claude:Current session'
echo '[使用上限] Claude の Current session（claude:Current session）' >"$test_dir/get-title"
echo '{"is_error":false,"result":"Current session: 100% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
login_run
assert_legacy_read_once
[[ $(comment_count) == 1 ]]
jq -e '."claude:Current session" == {level: "limited", issue: "legacy-issue", keyed: true}' \
	"$(login_state_file)" >/dev/null
echo 'PASS 旧タスクの照合: 同じ実行で更新するときもサーバーのタスクを読み直さない'

# 使用上限の起票だけが失敗しても、ログインと後続ランタイムを処理する。
login_reset
legacy_state 'codex:old:300'
echo '[使用上限] Claude の Current session' >"$test_dir/fail-create-prefix"
echo '{"is_error":false,"result":"Current session: 100% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
claude_auth 0 "$(expiry_json 3)"
echo '{"id":2,"result":{"ordinaryUsageAllowed":true,"rateLimitsByLimitId":{"codex":{"primary":{"windowDurationMins":10080,"usedPercent":80,"resetsAt":604800},"secondary":null}}}}' >"$test_dir/codex.jsonl"
rc=0
login_run 'claude codex' || rc=$?
[[ $rc == 1 ]]
grep -qF 'mock create failure' "$test_dir/err"
assert_legacy_read_once
jq -e '(has("claude:Current session") | not) and (has("codex:old:300") | not)
	and ."login:claude".level == "warn" and ."codex:codex:10080".level == "warn"
	and ."login:codex".level == "ok"' "$(login_state_file)" >/dev/null
jq -se '[.[] | select(.[0:2] == ["issue", "create"]) | .[3]] ==
	["[使用上限] Claude の Current session（claude:Current session）",
	 "[ログイン] Claude Code のログインの期限（login:claude）",
	 "[使用上限] Codex の codex の週の枠（codex:codex:10080）"]' "$test_dir/calls.jsonl" >/dev/null
echo 'PASS 起票の失敗: 失敗した行を進めず、ログインと後続ランタイムを更新する'

# 既存タスクを読めず時間切れになった行は、同じ実行で読み直さず前回の状態を残す。
login_reset
legacy_state 'claude:Current session'
echo '{"is_error":false,"result":"Current session: 100% used · resets Oct 27 at 12:29pm (Asia/Tokyo)"}' >"$test_dir/claude.json"
claude_auth 0 "$(expiry_json 3)"
touch "$test_dir/hang-get"
rc=0
login_run 'claude codex' USAGE_TASK_READ_SECONDS=2 || rc=$?
[[ $rc == 1 ]]
grep -qF 'サーバーから読めなかった' "$test_dir/err"
assert_legacy_read_once
jq -e '."claude:Current session" == {level: "warn", issue: "legacy-issue"}
	and ."login:claude".level == "warn" and ."login:codex".level == "ok"' "$(login_state_file)" >/dev/null
[[ $(comment_count) == 0 ]]
echo 'PASS 既存タスクの時間切れ: その行を保ち、ログインと後続ランタイムを更新する'

# 題と本文だけの失敗は、状態を進め、次の実行でコメントなしに書き換える。
login_reset
mkdir -p "$(dirname "$(login_state_file)")"
login_prev_state warn
claude_auth 1 '{"loggedIn":false}'
touch "$test_dir/fail-update"
rc=0
login_run || rc=$?
[[ $rc == 1 && $(comment_count) == 1 ]]
jq -e '."login:claude" == {level: "error", issue: "login-issue", keyed: true, retitle: true}' \
	"$(login_state_file)" >/dev/null
reset_server
login_run
[[ $(comment_count) == 0 ]]
jq -se 'length == 1 and .[0].title == "[ログイン] Claude Code のログイン（login:claude）"
	and (.[0].description | startswith("ログインしていない。"))' "$test_dir/updates.jsonl" >/dev/null
jq -e '."login:claude" == {level: "error", issue: "login-issue", keyed: true}' "$(login_state_file)" >/dev/null
jq -se '[.[] | select(.[0:2] == ["issue", "get"])] == [["issue","get","login-issue","--output","json"]]' \
	"$test_dir/calls.jsonl" >/dev/null
echo 'PASS retitle: 次の実行で確認して題と本文だけを書き換え、印を外す'
