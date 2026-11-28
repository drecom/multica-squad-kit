#!/usr/bin/env bash
# squad-review-wait-*-test.sh が読み込む共通の準備。単独では実行しない。

mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/review-wait-test.XXXXXX")
source "$root/tests/arg-limit-lib.sh"
trap 'arg_limit_finish $? "$test_dir"' EXIT
# 見張りは、同じ場所にある squad-review-next を呼ぶので、写しと見本を置いた場所から流す。
mkdir -p "$test_dir/monitor"
cp "$root/common/monitor/squad-review-wait" "$root/common/monitor/squad-cli-lib" "$test_dir/monitor/"
script="$test_dir/monitor/squad-review-wait"
# 次の依頼を決めるスクリプトの代わり。受けた引数と、そのときまでに投稿した数を記録し、決めた出力と終了コードを返す。
cat >"$test_dir/monitor/squad-review-next" <<'EOF2'
#!/usr/bin/env bash
dir=$REVIEW_WAIT_TEST_DIR
printf '%s\n' "$*" >>"$dir/decide-calls"
jq -s length "$dir/posted.jsonl" >>"$dir/decide-posted-at"
[[ ! -f $dir/decide-err ]] || cat "$dir/decide-err" >&2
[[ ! -f $dir/decide-out ]] || cat "$dir/decide-out"
if [[ -f $dir/decide-status ]]; then exit "$(<"$dir/decide-status")"; fi
exit 0
EOF2
chmod +x "$test_dir/monitor/squad-review-next"
export REVIEW_WAIT_TEST_DIR="$test_dir"
export REVIEW_WAIT_TEST_ROOT="$root"
source "$root/common/monitor/squad-cli-lib"
squad_cli_contracts >"$test_dir/contracts.json"
fixture() { python3 "$root/tests/review-wait-fixture.py" base "$@"; }
fixture issue-comments agent >"$test_dir/comment-prototype.json"
export REVIEW_WAIT_LIMIT_MINUTES=60
mkdir -p "$test_dir/bin"
# Linux の引数の上限を超える jq の呼び出しを拒む包み。拒んだ呼び出しは、終わるときに記録を確認する。
install_arg_limit_jq "$test_dir/bin" "$test_dir/rejected-calls"
export PATH="$test_dir/bin:$PATH"

cat >"$test_dir/bin/multica" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$REVIEW_WAIT_TEST_DIR
stub_args=("$@")
# 記録と見本の返却は、補助の 1 回の呼び出しで済ませる。見本を返さずに終わる呼び出しは、終了時に記録だけする。
stub() { recorded=1; python3 "$REVIEW_WAIT_TEST_ROOT/tests/cli-stub.py" review-wait "$dir" multica calls.jsonl "$@" -- ${stub_args[@]+"${stub_args[@]}"}; }
recorded=
trap '[[ -n $recorded ]] || stub record' EXIT
if [[ -f $dir/fail && "${1-} ${2-} ${3-}" == "$(<"$dir/fail")" ]]; then
	echo 'CLI mock failure' >&2
	exit 1
fi
emit() { stub "$@"; }
case "${1-} ${2-} ${3-}" in
'version  ') echo 'multica fixture-version' ;;
'squad list --output') emit emit squad-list "$dir/squads.json" ;;
"agent get $3")
 jq --arg id "$3" '.[] | select(.id == $id)' "$dir/agents.json" >"$dir/agent-response.json"
 emit emit agent-get "$dir/agent-response.json" ;;
'issue comment list')
	# 読み直しごとに別の中身を返せるよう、n 回目の呼び出しには comments.<n>.json があればそれを返す。
	n=$(($(<"$dir/list-count") + 1))
	echo "$n" >"$dir/list-count"
	if [[ -f $dir/fail-list-at && $n == "$(<"$dir/fail-list-at")" ]]; then
		echo 'CLI mock comment list failure' >&2
		exit 1
	fi
	if [[ -f $dir/comments.$n.json ]]; then emit emit issue-comments "$dir/comments.$n.json"; else emit emit issue-comments "$dir/comments.json"; fi
	;;
'issue comment add')
	n=$(($(jq -s length "$dir/posted.jsonl") + 1))
	if [[ -f $dir/fail-add-at && $n == "$(<"$dir/fail-add-at")" ]]; then
		echo 'CLI mock comment add failure' >&2
		exit 1
	fi
	args=$(jq -cn --args '$ARGS.positional' -- "$@")
	file=$(jq -er 'index("--content-file") as $i | .[$i+1]' <<<"$args")
	jq -Rs --argjson args "$args" '{args: $args, body: .}' <"$file" >>"$dir/posted.jsonl"
	emit posted issue-comment-add "posted-$n"
	;;
'issue get test-issue') emit emit issue-get "$dir/issue.json" ;;
'issue runs test-issue') emit emit issue-runs "$dir/runs.json" ;;
'issue wakeup list') emit emit issue-wakeups "$dir/rules.json" ;;
'issue wakeup delete') echo '{}' ;;
'issue wakeup create')
	while (($#)); do
		if [[ $1 == --instruction-file ]]; then
			jq -Rs --arg path "$2" '{path: $path, instruction: .}' <"$2" >>"$dir/instructions.jsonl"
			break
		fi
		shift
	done
	emit posted issue-wakeup-create wakeup-created
	;;
*) echo "Unexpected mock call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$test_dir/bin/multica"

# report と proceed の待ちは、実際には待たずに秒数だけ記録する。
cat >"$test_dir/bin/sleep" <<'EOF'
#!/usr/bin/env bash
echo "$1" >>"$REVIEW_WAIT_TEST_DIR/sleeps.log"
EOF
chmod +x "$test_dir/bin/sleep"
export REVIEW_WAIT_RECHECK_SECONDS=20

# status の時計を固定し、登録と依頼コメントの数秒差も再現する。
cat >"$test_dir/bin/date" <<'EOF'
#!/usr/bin/env bash
[[ $# == 1 && $1 == +%s ]] || exit 1
printf '%s\n' "$REVIEW_WAIT_TEST_NOW"
EOF
chmod +x "$test_dir/bin/date"
export REVIEW_WAIT_TEST_NOW=1792947600

a=agent-a
b=agent-b
mark='レビューと E2E の返事の待ちの見張りで起きました。'
fixture agent-get | jq --arg a "$a" --arg b "$b" '. as $base | [
	$base + {id: $a, name: "demo-code-reviewer-test", archived_at: null},
	$base + {id: $b, name: "demo-qa-test", archived_at: null},
	$base + {id: "archived", name: "demo-qa-test", archived_at: "2026-01-01T00:00:00Z"},
	$base + {id: "orchestrator", name: "orchestrator", archived_at: null}
]' >"$test_dir/agents.json"
fixture issue-wakeups | jq --arg mark "$mark" '. as $base | [
	$base + {id: "old-active", enabled: true, instruction: ($mark + "\nold round")},
	$base + {id: "old-disabled", enabled: false, instruction: $mark},
	$base + {id: "ci", instruction: "PR の CI が終わりました。"},
	$base + {id: "conflicts", instruction: "PR のコンフリクトの見張りで起きました。"},
	$base + {id: "other", instruction: ""}
]' >"$test_dir/rules.json"

fixture squad-list | jq '[. + {id:"squad-test", name:"demo-squad", leader_id:"orchestrator", archived_at:null}]' >"$test_dir/squads.base.json"
cp "$test_dir/squads.base.json" "$test_dir/squads.json"
# タスクの担当。既定は squad-test。set_assignee で、別のスクワッドや、スクワッドでない担当（agent）に変えられる。
fixture issue-get | jq '. + {assignee_type: "squad", assignee_id: "squad-test"}' >"$test_dir/issue.base.json"
set_assignee() { # 担当の種類 担当の ID
	jq --arg type "$1" --arg id "$2" '. + {assignee_type: $type, assignee_id: $id}' "$test_dir/issue.base.json" >"$test_dir/issue.json"
}

reset_calls() {
	cp "$test_dir/squads.base.json" "$test_dir/squads.json"
	cp "$test_dir/issue.base.json" "$test_dir/issue.json"
	: >"$test_dir/calls.jsonl"
	: >"$test_dir/instructions.jsonl"
	: >"$test_dir/posted.jsonl"
	: >"$test_dir/sleeps.log"
	echo 0 >"$test_dir/list-count"
	rm -f "$test_dir"/comments.[0-9]*.json
	rm -f "$test_dir/fail-list-at" "$test_dir/fail-add-at"
	rm -f "$test_dir/decide-calls" "$test_dir/decide-posted-at" "$test_dir/decide-err" "$test_dir/decide-out" "$test_dir/decide-status"
	rm -f "$test_dir/allow-missing-fields" "$test_dir/issue-comment-add-response.json" "$test_dir/issue-wakeup-create-response.json"
}

assert_jq() {
	jq -e "$@" >/dev/null
}

now=$(date +%s)
round_ts=$((now - 120))
round_time=$(jq -nr --argjson ts "$round_ts" '$ts | todateiso8601 | sub("Z$"; ".500Z")')

round_comments() {
	fixture issue-comments agent | jq --arg a "$a" --arg b "$b" --arg time "$round_time" '. as $base | [$base + {
		id: "round", author_type: "agent", author_id: "orchestrator", created_at: $time,
		content: ("返事を待つ役: [@review](mention://agent/" + $a + ") [@qa](mention://agent/" + $b + ")\n観点: qa（テスト）")
	}]' >"$test_dir/comments.json"
}

run_fixture() {
	local agent=$1 state=$2 ts=$3 error=${4:-}
	fixture issue-runs comment | jq --arg agent "$agent" --arg state "$state" --argjson ts "$ts" --arg error "$error" \
		'. + {agent_id: $agent, status: $state, created_at: ($ts | todateiso8601), error: $error, trigger_comment_id: "previous-round", delivered_comment_ids: []}'
}

check_status() {
	local expected=$1 output
	shift
	output=$(bash "$script" status test-issue "$@")
	[[ $output == "$expected" ]] || {
		printf '期待した出力:\n%s\n実際の出力:\n%s\n' "$expected" "$output" >&2
		exit 1
	}
}

# status が、読めない候補で何も出さず、何も書かず、理由を標準エラーに出して終了 1 になる。
check_status_blocked() { # 標準エラーに含まれる理由
	local output code=0
	output=$(bash "$script" status test-issue 2>"$test_dir/status-err") || code=$?
	[[ $code == 1 ]] || { printf '終了コード 1 を期待したが %s（出力: %s）\n' "$code" "$output" >&2; exit 1; }
	[[ -z $output ]] || { printf '何も出してはいけない: %s\n' "$output" >&2; exit 1; }
	[[ $(<"$test_dir/status-err") == *"$1"* ]] || { printf '標準エラーに「%s」がない: %s\n' "$1" "$(<"$test_dir/status-err")" >&2; exit 1; }
	[[ ! -s $test_dir/posted.jsonl ]] || { printf 'コメントを書いてはいけない: %s\n' "$(<"$test_dir/posted.jsonl")" >&2; exit 1; }
}

# ここから report と proceed。回は 2 役（a, b）を待つ。

# 回に、返事（result: /note 付き、plain-result: ふつう）、そろった知らせ（ready）、次へ回す記録（claim）を足したコメントの一覧を出す。
# 引数は「種類:役:ID:回からの秒」。役は a、b、orch。種類に decide（決める記録）と next（次の依頼の制御記録。修正の依頼）もある。
build_comments() {
	local spec kind who id sec content out
	round_comments
	out=$(<"$test_dir/comments.json")
	for spec in "$@"; do
		IFS=: read -r kind who id sec <<<"$spec"
		case $who in a) who=$a ;; b) who=$b ;; orch) who=orchestrator ;; esac
		case $kind in
		result) content=$'/note\nresult' ;;
		plain-result) content='result' ;;
		ready) content='返事がそろいました。' ;;
		claim) content=$'/note\n返事の待ち: この回を次へ回します' ;;
		decide) content=$'/note\n返事の待ち: 次の依頼を決めます' ;;
		next) content=$'修正の依頼: 直してください\n前の回: round' ;;
		esac
		out=$(jq --slurpfile comment "$test_dir/comment-prototype.json" --arg who "$who" --arg id "$id" --arg content "$content" \
			--arg time "$(jq -nr --argjson ts "$((round_ts + sec))" '$ts | todateiso8601')" \
			'. + [$comment[0] + {id: $id, author_type: "agent", author_id: $who, created_at: $time, content: $content}]' <<<"$out")
	done
	printf '%s\n' "$out"
}

# コメントを 1 件足した一覧を出す。引数は「ID 作者の ID 作者の種類 回からの秒 本文」。標準入力が一覧。
with_raw() {
	jq --slurpfile comment "$test_dir/comment-prototype.json" --arg id "$1" --arg who "$2" --arg type "$3" --arg content "$5" \
		--arg time "$(jq -nr --argjson ts "$((round_ts + $4))" '$ts | todateiso8601')" \
		'. + [$comment[0] + {id: $id, author_type: $type, author_id: $who, created_at: $time, content: $content}]'
}

# with_raw の JSON 形式。本文は JSON の文字列で渡す（NUL や単独の CR を含められる）。
with_json() {
	jq --slurpfile comment "$test_dir/comment-prototype.json" --arg id "$1" --arg who "$2" --arg type "$3" --argjson content "$5" \
		--arg time "$(jq -nr --argjson ts "$((round_ts + $4))" '$ts | todateiso8601')" \
		'. + [$comment[0] + {id: $id, author_type: $type, author_id: $who, created_at: $time, content: $content}]'
}

# 読めない候補の名乗りのコメントを足した一覧を出す。引数は「ID 作者の ID 回からの秒 候補の ID スクワッドの ID」。標準入力が一覧。
with_claim() {
	with_raw "$1" "$2" agent "$3" "$(printf '/note\n読めない制御記録の知らせ: %s %s\n' "$4" "$5")"
}

# 読めない候補が 1 つのとき、名乗りを書いたあとの読み直し（3 回目の一覧の取得）で自分の名乗りが見えるよう、comments.3.json を作る。
# 結果が posted-1、名乗りが posted-2。comments.json は、結果を書く前の一覧にしておく。引数は候補の ID。
claim_visible_at_3() {
	with_claim posted-2 "$b" 12 "$1" squad-test <"$test_dir/comments.json" >"$test_dir/comments.3.json"
}

posted_claim_count() {
	jq -s '[.[] | select(.body == "/note\n返事の待ち: この回を次へ回します\n")] | length' "$test_dir/posted.jsonl"
}
posted_ready_count() {
	jq -s '[.[] | select(.body | contains("返事がそろいました"))] | length' "$test_dir/posted.jsonl"
}
posted_decide_count() {
	jq -s '[.[] | select(.body == "/note\n返事の待ち: 次の依頼を決めます\n")] | length' "$test_dir/posted.jsonl"
}
decide_calls() { if [[ -f $test_dir/decide-calls ]]; then paste -sd';' "$test_dir/decide-calls"; fi; }
list_count() { cat "$test_dir/list-count"; }
slept() { paste -sd, "$test_dir/sleeps.log"; }
deleted_rules() {
	jq -s '[.[] | select(.[0:3] == ["issue", "wakeup", "delete"])] | length' "$test_dir/calls.jsonl"
}

printf '/note\nqa result\n' >"$test_dir/result.md"
