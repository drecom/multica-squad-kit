#!/usr/bin/env bash
# squad-review-next-test.sh と squad-review-next-arg-limit-test.sh が読み込む共通の準備（スタブ・見本・補助）。単独では実行しない。
# squad-review-wait を差し替え、multica と gh は見本で照合する偽の CLI にする。
# 実際のタスク・PR・エージェントには書き込まない。
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/review-next-test.XXXXXX")
source "$root/tests/arg-limit-lib.sh"
trap 'arg_limit_finish $? "$test_dir"' EXIT
export REVIEW_NEXT_TEST_DIR=$test_dir REVIEW_NEXT_TEST_ROOT=$root REVIEW_WAIT_TEST_DIR=$test_dir
# 呼び出したリーダーは、各ケースが決める。実行している環境の値を使わない。
unset MULTICA_AGENT_ID
source "$root/common/monitor/squad-cli-lib"
squad_cli_contracts >"$test_dir/contracts.json"
fixture() { python3 "$root/tests/review-wait-fixture.py" base "$@"; }

mkdir -p "$test_dir/monitor" "$test_dir/bin"
cp "$root/common/monitor/squad-review-next" "$root/common/monitor/squad-cli-lib" "$test_dir/monitor/"
# Linux の引数の上限を超える jq の呼び出しを拒む包み。拒んだ呼び出しは、終わるときに記録を確認する。
install_arg_limit_jq "$test_dir/bin" "$test_dir/rejected-calls"
export PATH="$test_dir/bin:$PATH"

# 返事の待ちの見張りの代わり。受けた引数を記録し、決めた終了コードを返す。
cat >"$test_dir/monitor/squad-review-wait" <<'EOF'
#!/usr/bin/env bash
dir=$REVIEW_NEXT_TEST_DIR
printf '%s\n' "$*" >>"$dir/watch-calls"
exit "$(<"$dir/watch-status")"
EOF
chmod +x "$test_dir/monitor/squad-review-wait"

cat >"$test_dir/bin/multica" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$REVIEW_NEXT_TEST_DIR
stub_args=("$@")
stub() { python3 "$REVIEW_NEXT_TEST_ROOT/tests/cli-stub.py" review-wait "$dir" multica calls.jsonl "$@" -- ${stub_args[@]+"${stub_args[@]}"}; }
case "${1-} ${2-} ${3-}" in
'version  ') echo 'multica fixture-version' ;;
'issue get test-issue') stub emit issue-get "$dir/issue.json" ;;
'issue comment list')
	[[ ! -f $dir/comments-fail ]] || { echo 'CLI mock comment list failure' >&2; exit 1; }
	stub emit issue-comments "$dir/comments.json" ;;
'issue label list') [[ ! -f $dir/labels-fail ]] || { echo 'CLI mock label failure' >&2; exit 1; }
	stub emit issue-labels "$dir/issue-labels.json" ;;
'label list --output') stub emit label-list "$dir/labels.json" ;;
'squad list --output') stub emit squad-list "$dir/squads.json" ;;
'squad member list') stub emit squad-member-list "$dir/members.json" ;;
"agent get $3")
	jq --arg id "$3" '.[] | select(.id == $id)' "$dir/agents.json" >"$dir/agent-response.json"
	stub emit agent-get "$dir/agent-response.json" ;;
'issue comment add')
	[[ ! -f $dir/post-fail ]] || { echo 'CLI mock comment add failure' >&2; exit 1; }
	args=$(jq -cn --args '$ARGS.positional' -- "$@")
	file=$(jq -er 'index("--content-file") as $i | .[$i+1]' <<<"$args")
	jq -Rs --argjson args "$args" '{args: $args, body: .}' <"$file" >>"$dir/posted.jsonl"
	stub posted issue-comment-add posted-comment ;;
*) echo "Unexpected mock call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$test_dir/bin/multica"

cat >"$test_dir/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$REVIEW_NEXT_TEST_DIR
stub_args=("$@")
stub() { python3 "$REVIEW_NEXT_TEST_ROOT/tests/cli-stub.py" gh "$dir" gh calls-gh.jsonl "$@" -- ${stub_args[@]+"${stub_args[@]}"}; }
if [[ ${1-} == pr && ${2-} == view ]]; then
	[[ ${3-} == 7 && ${4-} == --repo && ${5-} == demo/project ]] || { echo "Unexpected mock call: $*" >&2; exit 1; }
	[[ ! -f $dir/pr-fail ]] || { echo 'gh mock pr failure' >&2; exit 1; }
	stub emit gh-dependabot-pr "$dir/pr.json"
elif [[ ${1-} == api ]]; then
	case "${2-}" in
	# ホストの gh のガードが入っている環境では、ガードが本物の gh の help でフラグを読む。
	--help)
		printf 'FLAGS\n      --paginate        Make additional HTTP requests to fetch all pages of results\n  -X, --method string   The HTTP method for the request\n' ;;
	'repos/demo/project/pulls/7/files?per_page=100')
		[[ ${3-} == --paginate ]]
		[[ ! -f $dir/files-fail ]] || { echo 'gh: Bad Gateway (HTTP 502)' >&2; exit 1; }
		stub emit gh-pr-files "$dir/files.json" ;;
	'repos/demo/project/contents/.agents/review-paths?ref='*)
		echo "${2#*ref=}" >>"$dir/paths-refs"
		case $(<"$dir/paths-mode") in
		absent) echo 'gh: Not Found (HTTP 404)' >&2; exit 1 ;;
		error) echo 'gh: Internal Server Error (HTTP 500)' >&2; exit 1 ;;
		*) stub emit gh-file "$dir/paths-file.json" ;;
		esac ;;
	*) echo "Unexpected mock call: $*" >&2; exit 1 ;;
	esac
else
	echo "Unexpected mock call (書き込みは禁止): $*" >&2
	exit 1
fi
EOF
chmod +x "$test_dir/bin/gh"

fail() { printf '%s\n' "$*" >&2; exit 1; }
sha=0123456789abcdef0123456789abcdef01234567

# --- 見本。エージェントの名前は <プロジェクトのキー>-<役>-<メンバーのキー> で、スクワッドの名前は DEMO-TEST。
jq '.[2] + {assignee_type: "squad", assignee_id: "squad-test"}
	| .metadata += {pr_url: "https://github.com/demo/project/pull/7", repository: "demo/project"}' \
	"$root/tests/fixtures/cli/issue-get.json" >"$test_dir/issue.base.json"
fixture squad-list | jq '[. + {id: "squad-test", name: "DEMO-TEST", leader_id: "orchestrator", archived_at: null}]' >"$test_dir/squads.json"
fixture agent-get | jq '. as $base | [
	"code-reviewer", "ux-reviewer", "security-reviewer", "performance-reviewer", "qa", "claude-implementer"
	| . as $role | $base + {id: $role, name: ("demo-" + $role + "-test"), model: "claude-sonnet-5-5", archived_at: null}
] + [
	$base + {id: "orchestrator", name: "demo-orchestrator-test", model: "claude-fable-5-2", archived_at: null},
	$base + {id: "archived-qa", name: "demo-qa-test", model: "claude-sonnet-5-5", archived_at: "2026-01-01T00:00:00Z"},
	$base + {id: "other-ux-reviewer", name: "other-ux-reviewer-test", model: "claude-sonnet-5-5", archived_at: null}
]' >"$test_dir/agents.json"
set_roster() {
	fixture squad-member-list | jq --args '. as $base | [$ARGS.positional[] | $base + {member_id: ., member_type: "agent"}]' -- "$@" >"$test_dir/members.json"
}
fixture label-list | jq '. as $base | [
	$base + {id: "label-imp", name: "重要", resource_type: "issue"},
	$base + {id: "label-dev", name: "開発", resource_type: "issue"},
	$base + {id: "label-imp-project", name: "重要", resource_type: "project"}
]' >"$test_dir/labels.json"
set_issue_labels() { # ラベルの ID...
	fixture issue-labels | jq --args '. as $base | [$ARGS.positional[] | $base + {id: .}]' -- "$@" >"$test_dir/issue-labels.json"
}
set_files() { # ファイル名[:前の名前]...
	fixture gh-pr-files | jq --args '. as $base | [$ARGS.positional[] | split(":") as $p
		| $base + {filename: $p[0], status: (if $p[1] then "renamed" else "modified" end)}
		| if $p[1] then del(.patch) + {previous_filename: $p[1]} else . end]' -- "$@" >"$test_dir/files.json"
}
set_paths() { # 対応ファイルの内容（標準入力）
	local content
	content=$(base64 | tr -d '\n')
	fixture gh-file | jq --arg content "$content" '. + {content: $content, encoding: "base64", type: "file"}' >"$test_dir/paths-file.json"
	echo present >"$test_dir/paths-mode"
}
all_roles=(code-reviewer ux-reviewer security-reviewer performance-reviewer qa)

status=0
reset() {
	: >"$test_dir/calls.jsonl"
	: >"$test_dir/calls-gh.jsonl"
	: >"$test_dir/watch-calls"
	: >"$test_dir/posted.jsonl"
	: >"$test_dir/paths-refs"
	rm -f "$test_dir/comments-fail" "$test_dir/labels-fail" "$test_dir/post-fail" "$test_dir/pr-fail" "$test_dir/files-fail"
	echo 0 >"$test_dir/watch-status"
	echo absent >"$test_dir/paths-mode"
	echo '[]' >"$test_dir/comments.json"
	cp "$test_dir/issue.base.json" "$test_dir/issue.json"
	jq '.baseRefName = "release"' <(fixture gh-dependabot-pr) >"$test_dir/pr.json"
	set_roster claude-implementer orchestrator "${all_roles[@]}" archived-qa other-ux-reviewer
	set_issue_labels label-dev
	set_files README.md
}
run() {
	status=0
	(cd "$test_dir" && bash monitor/squad-review-next request test-issue trigger-1 "$sha" "$@") >"$test_dir/out" 2>"$test_dir/err" || status=$?
}
expect_status() {
	[[ $status == "$1" ]] || { printf '終了コード %s を期待したが %s\n出力:\n%s\n標準エラー:\n%s\n' "$1" "$status" "$(<"$test_dir/out")" "$(<"$test_dir/err")" >&2; exit 1; }
}
# 書いた依頼のコメントを、行ごとに確認する。引数は、観点の役（読点で区切った順）と、理由。
expect_request() {
	local roles=$1 reason=$2 mentions='' role id
	for role in ${roles//、/ }; do
		mentions+="${mentions:+ }[@demo-${role}-test](mention://agent/${role})"
	done
	expect_status 0
	[[ $(jq -s length "$test_dir/posted.jsonl") == 1 ]] || fail "コメントが 1 件でない: $(<"$test_dir/posted.jsonl")"
	jq -e '.args[0:3] == ["issue", "comment", "add"] and .args[3] == "test-issue" and (.args | index("--parent") as $i | .[$i + 1]) == "trigger-1"' "$test_dir/posted.jsonl" >/dev/null \
		|| fail "投稿の引数が違う: $(<"$test_dir/posted.jsonl")"
	local expected actual
	expected=$(printf '確認するコミット: %s\n返事を待つ役: %s\n観点: %s（%s）\n対象の PR: https://github.com/demo/project/pull/7\n' "$sha" "$mentions" "$roles" "$reason")
	[[ -z ${3-} ]] || expected+=$'\n'"$3"
	actual=$(jq -rs '.[0].body' "$test_dir/posted.jsonl")
	[[ $actual == "$expected" ]] || { printf '期待したコメント:\n%s\n実際のコメント:\n%s\n標準エラー:\n%s\n' "$expected" "$actual" "$(<"$test_dir/err")" >&2; exit 1; }
	# 見張りは、同じ役の ID を同じ順で、きっかけのコメントとともに 1 回だけ入れる。
	local watch=${roles//、/ }
	[[ $(<"$test_dir/watch-calls") == "watch test-issue trigger-1 $watch" ]] || fail "見張りの引数が違う: $(<"$test_dir/watch-calls")"
	[[ $(<"$test_dir/out") == $'観点: '"${roles}（${reason}）"$'\n依頼: posted-comment' ]] || fail "標準出力が違う: $(<"$test_dir/out")"
}
expect_no_comment() {
	[[ ! -s $test_dir/posted.jsonl ]] || fail "コメントを書いてはいけない: $(<"$test_dir/posted.jsonl")"
}
all='code-reviewer、ux-reviewer、security-reviewer、performance-reviewer、qa'
all_reason() { printf '対応を読めないため、有効な観点をすべて頼む: %s' "$1"; }
