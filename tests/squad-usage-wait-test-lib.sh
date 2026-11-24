#!/usr/bin/env bash
# squad-usage-wait のテストの共通の部分。テストではないので、-test.sh で終えない。
# 各テストが source する。作業ディレクトリ、スタブ（squad-dispatch-pick、squad-usage-read、date、multica）、名簿と見本、reset・run・run_answer などの補助の関数を置く。
# 呼ぶテストは、先に root（リポジトリのルート）を決める。
cd "$root"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/usage-wait-test.XXXXXX")
source "$root/tests/arg-limit-lib.sh"
trap 'arg_limit_finish $? "$test_dir"' EXIT
export USAGE_WAIT_TEST_DIR=$test_dir USAGE_WAIT_TEST_ROOT=$root REVIEW_WAIT_TEST_DIR=$test_dir
# 呼び出したリーダーは、各ケースが決める。実行している環境の値を使わない。
unset MULTICA_AGENT_ID
source "$root/common/monitor/squad-cli-lib"
squad_cli_contracts >"$test_dir/contracts.json"
fixture() { python3 "$root/tests/review-wait-fixture.py" base "$@"; }

mkdir -p "$test_dir/monitor" "$test_dir/bin"
cp "$root/common/monitor/squad-usage-wait" "$root/common/monitor/squad-cli-lib" "$test_dir/monitor/"
# Linux の引数の上限を超える jq の呼び出しを拒む包み。拒んだ呼び出しは、終わるときに記録を確認する。
install_arg_limit_jq "$test_dir/bin" "$test_dir/rejected-calls"
export PATH="$test_dir/bin:$PATH"

# 振り分けの代わり。受けた引数を記録し、決めた出力と終了コードを返す。
# 末尾が --allow-near の呼び出しには、dispatch-near-status があればそちらの出力と終了コードを返す。
cat >"$test_dir/monitor/squad-dispatch-pick" <<'EOF'
#!/usr/bin/env bash
dir=$USAGE_WAIT_TEST_DIR
printf '%s\n' "$*" >>"$dir/dispatch-calls"
if [[ ${!#} == --allow-near && -f $dir/dispatch-near-status ]]; then
	cat "$dir/dispatch-near-out" 2>/dev/null || true
	exit "$(<"$dir/dispatch-near-status")"
fi
cat "$dir/dispatch-out" 2>/dev/null || true
exit "$(<"$dir/dispatch-status")"
EOF
# 使用率の読み取りの代わり。
cat >"$test_dir/monitor/squad-usage-read" <<'EOF'
#!/usr/bin/env bash
dir=$USAGE_WAIT_TEST_DIR
echo x >>"$dir/usage-reads"
cat "$dir/usage.json"
exit "$(<"$dir/usage-status")"
EOF
chmod +x "$test_dir/monitor/squad-dispatch-pick" "$test_dir/monitor/squad-usage-read"

now=1793059200
cat >"$test_dir/bin/date" <<'EOF'
#!/usr/bin/env bash
[[ $# == 1 && $1 == +%s ]] || exit 1
printf '%s\n' "$USAGE_WAIT_TEST_NOW"
EOF
chmod +x "$test_dir/bin/date"
export USAGE_WAIT_TEST_NOW=$now

cat >"$test_dir/bin/multica" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$USAGE_WAIT_TEST_DIR
stub_args=("$@")
stub() { python3 "$USAGE_WAIT_TEST_ROOT/tests/cli-stub.py" review-wait "$dir" multica calls.jsonl "$@" -- ${stub_args[@]+"${stub_args[@]}"}; }
# 引数の取り出しは jq でなく bash で走査する。スタブの 1 回の呼び出しで起こす jq は 1 回までにするため。
opt() { # 名前: 引数の中で、名前の次の値
	local name=$1 i j
	for ((i = 1; i <= ${#stub_args[@]}; i++)); do
		if [[ ${stub_args[i - 1]} == "$name" ]]; then j=$i; printf '%s' "${stub_args[j]}"; return; fi
	done
	return 1
}
json_args() { # 受けた引数を JSON の配列 1 行にする
	local out='' a
	for a in "${stub_args[@]}"; do a=${a//\\/\\\\}; a=${a//\"/\\\"}; out+=${out:+,}\"$a\"; done
	printf '[%s]' "$out"
}
count_lines() { local n=0; [[ ! -f $1 ]] || n=$(wc -l <"$1"); printf '%s' "$((n))"; }
case "${1-} ${2-} ${3-}" in
'version  ') echo 'multica fixture-version' ;;
'issue get test-issue') stub emit issue-get "$dir/issue.json" ;;
'squad list --output') stub emit squad-list "$dir/squads.json" ;;
'squad member list') stub emit squad-member-list "$dir/members.json" ;;
"agent get $3")
	jq --arg id "$3" '.[] | select(.id == $id)' "$dir/agents.json" >"$dir/agent-response.json"
	stub emit agent-get "$dir/agent-response.json" ;;
'issue comment list')
	# マークのあるほかのタスクのコメントは、comments-<タスク>.json。なければ、このタスクのコメントを返す。
	# comments-fail-<タスク> があれば、そのタスクのコメントを読めない。
	if [[ -f $dir/comments-fail-$4 ]]; then echo 'comment list failed' >&2; exit 1; fi
	file=$dir/comments-$4.json
	[[ -f $file ]] || file=$dir/comments.json
	stub emit issue-comments "$file" ;;
'issue comment add')
	# comment-add-fail-<タスク> があれば、そのタスクにコメントを書けない。
	if [[ -f $dir/comment-add-fail-$4 ]]; then echo 'comment add failed' >&2; exit 1; fi
	file=$(opt --content-file)
	parent=$(opt --parent)
	new_id=comment-new
	if [[ -f $dir/apply-writes ]]; then
		# apply-writes があれば、書いたコメントを、次に読むときのそのタスクのコメントに足す。
		new_id=written-$(($(count_lines "$dir/posted-comments.jsonl") + 1))
		target=$dir/comments-$4.json
		[[ -f $target ]] || target=$dir/comments.json
		{ IFS= read -r posted; IFS= read -r updated; } < <(jq -c --slurpfile p "$dir/comment-agent.json" --arg id "$new_id" --arg issue "$4" --arg parent "$parent" --argjson now "$USAGE_WAIT_TEST_NOW" --rawfile content "$file" \
			'{issue: $issue, parent: $parent, content: $content}, (. + [$p[0] + {id: $id, author_id: "orchestrator", created_at: ($now | todateiso8601), parent_id: $parent, content: $content}])' "$target")
		printf '%s\n' "$posted" >>"$dir/posted-comments.jsonl"
		printf '%s\n' "$updated" >"$target"
	else
		jq -cn --arg issue "$4" --arg parent "$parent" --rawfile content "$file" '{issue: $issue, parent: $parent, content: $content}' >>"$dir/posted-comments.jsonl"
	fi
	stub posted issue-comment-add "$new_id" ;;
'issue list --metadata')
	# 絞り込みのある一覧（マーク）。issue-list-fail があれば読めない。
	if [[ -f $dir/issue-list-fail ]]; then echo 'issue list failed' >&2; exit 1; fi
	stub emit issue-list "$dir/issue-list.json" ;;
'issue list --limit')
	# 絞り込みのない一覧（answer だけが読む）。ページは issue-list-all-<offset>.json、なければ issue-list-all.json。
	# そのページを n 回目に読むとき、issue-list-all-<offset>-<n>.json があれば、それを返す（読み直しで変わる一覧）。
	if [[ -f $dir/issue-list-fail ]]; then echo 'issue list failed' >&2; exit 1; fi
	offset=$(opt --offset)
	echo x >>"$dir/list-reads-$offset"
	file=$dir/issue-list-all-$offset-$(count_lines "$dir/list-reads-$offset").json
	[[ -f $file ]] || file=$dir/issue-list-all-$offset.json
	[[ -f $file ]] || file=$dir/issue-list-all.json
	stub emit issue-list-all "$file" ;;
'issue metadata set')
	if [[ -f $dir/metadata-set-fail ]]; then echo 'metadata set failed' >&2; exit 1; fi
	printf '%s\n' "$(json_args)" >>"$dir/metadata-calls.jsonl"
	# マークのあるタスクの一覧に、そのタスクを足す。metadata-set-noop があれば足さない（書いたのに一覧に出ない）。
	if [[ ! -f $dir/metadata-set-noop ]]; then
		jq --slurpfile item "$dir/issue-list-item.json" --arg id "$4" \
			'if any(.issues[]; .id == $id) then . else .issues += [$item[0] + {id: $id, identifier: $id}] end | .total = (.issues | length)' \
			"$dir/issue-list.json" >"$dir/issue-list.tmp"
		mv "$dir/issue-list.tmp" "$dir/issue-list.json"
	fi
	echo '{}' ;;
'issue metadata delete')
	if [[ -f $dir/metadata-delete-fail ]]; then echo 'metadata delete failed' >&2; exit 1; fi
	printf '%s\n' "$(json_args)" >>"$dir/metadata-calls.jsonl"
	jq --arg id "$4" '.issues |= map(select(.id != $id)) | .total = (.issues | length)' "$dir/issue-list.json" >"$dir/issue-list.tmp"
	mv "$dir/issue-list.tmp" "$dir/issue-list.json"
	# reveal-on-delete-<タスク> があれば、マークを外した後に読むそのタスクのコメントを、それに差し替える。
	if [[ -f $dir/reveal-on-delete-$4 ]]; then cp "$dir/reveal-on-delete-$4" "$dir/comments-$4.json"; fi
	# fail-comments-on-delete-<タスク> があれば、マークを外した後は、そのタスクのコメントを読めない。fail-set-on-delete があれば、マークを外した後は、マークを置けない。
	if [[ -f $dir/fail-comments-on-delete-$4 ]]; then : >"$dir/comments-fail-$4"; fi
	if [[ -f $dir/fail-set-on-delete ]]; then : >"$dir/metadata-set-fail"; fi
	echo '{}' ;;
'issue wakeup list')
	# wakeup-list-fail があれば、その中の数だけ読めたあとから、読めない（空なら最初から）。
	if [[ -f $dir/wakeup-list-fail ]]; then
		allowed=$(<"$dir/wakeup-list-fail")
		reads=$(count_lines "$dir/wakeup-list-reads")
		echo x >>"$dir/wakeup-list-reads"
		if ((reads >= ${allowed:-0})); then echo 'wakeup list failed' >&2; exit 1; fi
	fi
	stub emit issue-wakeups "$dir/rules.json" ;;
'issue wakeup create')
	# wakeup-create-fail があれば置けない。置いた起こしは、次に読む一覧に現れる。
	if [[ -f $dir/wakeup-create-fail ]]; then echo 'wakeup create failed' >&2; exit 1; fi
	file=$(opt --instruction-file)
	stub record none
	{ IFS= read -r posted; IFS= read -r updated; } < <(jq -c --argjson args "$(json_args)" --arg agent "$(opt --agent-id)" --arg id "created-$(($(count_lines "$dir/wakeups.jsonl") + 1))" --rawfile instruction "$file" \
		'{args: $args, instruction: $instruction}, (. + [(.[0] + {id: $id, enabled: true, agent_id: $agent, instruction: $instruction})])' "$dir/rules.json")
	printf '%s\n' "$posted" >>"$dir/wakeups.jsonl"
	printf '%s\n' "$updated" >"$dir/rules.json"
	stub posted issue-wakeup-create wakeup-created ;;
'issue wakeup delete')
	# wakeup-delete-fail-<ID> か wakeup-delete-fail があれば消せない。<ID> の方の中身が gone なら、消せずに一覧から消えている。disabled なら無効になっている。
	stub record none
	echo "$5" >>"$dir/wakeup-deletes"
	for fail in "$dir/wakeup-delete-fail-$5" "$dir/wakeup-delete-fail"; do
		if [[ -f $fail ]]; then
			jq --arg id "$5" --arg how "$(<"$fail")" \
				'if $how == "gone" then map(select(.id != $id)) elif $how == "disabled" then map(if .id == $id then .enabled = false else . end) else . end' \
				"$dir/rules.json" >"$dir/rules.tmp"
			mv "$dir/rules.tmp" "$dir/rules.json"
			echo 'wakeup delete failed' >&2
			exit 1
		fi
	done
	jq --arg id "$5" 'map(select(.id != $id))' "$dir/rules.json" >"$dir/rules.tmp"
	mv "$dir/rules.tmp" "$dir/rules.json"
	echo '{}' ;;
*) echo "Unexpected mock call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$test_dir/bin/multica"

iso() { jq -nr --argjson epoch "$1" '$epoch | todateiso8601'; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
assert_jq() { jq -e "$@" >/dev/null; }
mark='使用率の待ちの起こしで起きました。'

# --- 名簿。エージェントの名前は <プロジェクトのキー>-<役>-<メンバーのキー> で、スクワッドの名前は DEMO-TEST。
fixture issue-get | jq '. + {assignee_type: "squad", assignee_id: "squad-test"}' >"$test_dir/issue.json"
fixture issue-get | jq '. + {assignee_type: "member", assignee_id: "member-test"}' >"$test_dir/issue-member.json"
fixture squad-list | jq '[. + {id: "squad-test", name: "DEMO-TEST", leader_id: "orchestrator", archived_at: null}]' >"$test_dir/squads.json"
fixture agent-get | jq '. as $base | [
	["claude-implementer", "claude-sonnet-5-5"], ["codex-implementer", "gpt-6.2-sol"],
	["claude-fixer", "claude-sonnet-5-5"], ["codex-fixer", "gpt-6.2-sol"],
	["claude-principal", "claude-fable-5-2"], ["codex-principal", "gpt-6.2-sol"],
	["planner", "claude-opus-5-5"], ["designer", "gpt-6.2-sol"]
	| . as [$role, $model] | $base + {id: $role, name: ("demo-" + $role + "-test"), model: $model, archived_at: null}
] + [
	$base + {id: "archived-codex-implementer", name: "demo-codex-implementer-test", model: "gpt-6.2-sol", archived_at: "2026-01-01T00:00:00Z"},
	$base + {id: "other-codex-fixer", name: "other-codex-fixer-test", model: "gpt-6.2-sol", archived_at: null},
	$base + {id: "orchestrator", name: "demo-orchestrator-test", model: "claude-fable-5-2", archived_at: null}
]' >"$test_dir/agents.json"
set_roster() {
	fixture squad-member-list | jq --args '. as $base | [$ARGS.positional[] | $base + {member_id: ., member_type: "agent"}]' -- "$@" >"$test_dir/members.json"
}
dual=(claude-implementer codex-implementer claude-fixer codex-fixer claude-principal codex-principal planner designer orchestrator)

# --- 起こしの規則とコメント。
fixture issue-wakeups | jq '. as $base | [$base + {id: "ci", enabled: true, agent_id: "orchestrator", instruction: "PR の CI が終わりました。"}]' >"$test_dir/rules.base.json"
fixture issue-comments agent >"$test_dir/comment-agent.json"
fixture issue-comments member >"$test_dir/comment-member.json"
echo '[]' >"$test_dir/comments.json"
add_comment() { # 種類（agent|member） 作者 ID 時刻 本文
	local proto=$test_dir/comment-$1.json
	jq --slurpfile p "$proto" --arg who "$2" --arg id "$3" --arg time "$(iso "$4")" --arg content "$5" \
		'. + [$p[0] + {id: $id, author_id: $who, created_at: $time, content: $content}]' "$test_dir/comments.json" >"$test_dir/comments.tmp"
	mv "$test_dir/comments.tmp" "$test_dir/comments.json"
}
add_rule() { # ID 有効か 指示 [宛先のエージェント。既定はリーダー]
	jq --arg id "$1" --argjson enabled "$2" --arg instruction "$3" --arg agent "${4:-orchestrator}" \
		'. + [(.[0] + {id: $id, enabled: $enabled, agent_id: $agent, instruction: $instruction})]' "$test_dir/rules.json" >"$test_dir/rules.tmp"
	mv "$test_dir/rules.tmp" "$test_dir/rules.json"
}

# 使用率。引数は、Claude の週（%、リセット時刻）、5 時間（%、リセット時刻）、Codex の週（%、リセット時刻）、利用可否。
usage() {
	jq -n --arg read "$(iso "$now")" --argjson cw "$1" --arg cwr "$(iso "$2")" --argjson cs "$3" --arg csr "$(iso "$4")" \
		--argjson xw "$5" --arg xwr "$(iso "$6")" --argjson xa "$7" \
		'{read_at: $read, claude: {week: {used_percent: $cw, resets_at: $cwr}, session: {used_percent: $cs, resets_at: $csr}},
			codex: {week: {used_percent: $xw, resets_at: $xwr}, allowed: $xa}}' >"$test_dir/usage.json"
	echo 0 >"$test_dir/usage-status"
}

# マークのあるタスクの一覧の見本。要素は、実物の見本の 1 件目に id と identifier を足して作る。
fixture issue-list | jq '.issues = [] | .has_more = false | .total = 0' >"$test_dir/issue-list.base.json"
fixture issue-list | jq '.issues[0]' >"$test_dir/issue-list-item.json"
set_marked() { # <id>:<identifier> ...
	jq --slurpfile item "$test_dir/issue-list-item.json" --args \
		'[$ARGS.positional[] | split(":") as [$id, $identifier] | $item[0] + {id: $id, identifier: $identifier}] as $items | .issues = $items | .total = ($items | length)' \
		-- "$@" <"$test_dir/issue-list.base.json" >"$test_dir/issue-list.json"
	set_all "${@/%/:$now}"
}
# 絞り込みのない一覧の見本。set_marked は、マークのあるタスクを、今動いたタスクとして、この一覧にも入れる。
fixture issue-list-all | jq '.issues = [] | .has_more = false | .total = 0' >"$test_dir/issue-list-all.base.json"
fixture issue-list-all | jq '.issues[0]' >"$test_dir/all-list-item.json"
write_all() { # 出力ファイル has_more（true|false） <id>:<identifier>:<最後の動きの時刻（秒。none なら空、bad なら読めない文字列）> ...
	local out=$1 more=$2
	shift 2
	jq --slurpfile item "$test_dir/all-list-item.json" --argjson more "$more" --argjson total "${list_total:-null}" --args \
		'[$ARGS.positional[] | split(":") as [$id, $identifier, $t]
			| $item[0] + {id: $id, identifier: $identifier, last_activity_at: (if $t == "none" then null elif $t == "bad" then "日付ではない" else ($t | tonumber | todateiso8601) end)}] as $items
			| .issues = $items | .has_more = $more | .total = ($total // ($items | length))' \
		-- "$@" <"$test_dir/issue-list-all.base.json" >"$out"
}
set_all() { write_all "$test_dir/issue-list-all.json" false "$@"; } # <id>:<identifier>:<時刻> ...
set_all_page() { local offset=$1 more=$2; shift 2; write_all "$test_dir/issue-list-all-$offset.json" "$more" "$@"; }
set_parent() { # ファイル名 コメントの ID 返信先
	jq --arg id "$2" --arg parent "$3" 'map(if .id == $id then .parent_id = $parent else . end)' "$test_dir/$1" >"$test_dir/$1.tmp"
	mv "$test_dir/$1.tmp" "$test_dir/$1"
}
add_task_comment() { # ファイル名 種類（agent|member） 作者 ID 時刻 本文
	local file=$test_dir/$1
	[[ -f $file ]] || echo '[]' >"$file"
	jq --slurpfile p "$test_dir/comment-$2.json" --arg who "$3" --arg id "$4" --arg time "$(iso "$5")" --arg content "$6" \
		'. + [$p[0] + {id: $id, author_id: $who, created_at: $time, content: $content}]' "$file" >"$file.tmp"
	mv "$file.tmp" "$file"
}

# 名簿と使用率の既定は、ここで 1 回だけ作り、reset は写すだけにする。
set_roster "${dual[@]}"
cp "$test_dir/members.json" "$test_dir/members.base.json"
usage 10 $((now + 100000)) 10 $((now + 10000)) 10 $((now + 100000)) true
cp "$test_dir/usage.json" "$test_dir/usage.base.json"

status=0
reset() {
	: >"$test_dir/calls.jsonl"
	: >"$test_dir/posted-comments.jsonl"
	: >"$test_dir/metadata-calls.jsonl"
	rm -f "$test_dir"/comments-*.json "$test_dir"/comments-fail-* "$test_dir"/comment-add-fail-* "$test_dir"/issue-list-all-*.json "$test_dir"/list-reads-* "$test_dir/metadata-set-fail" "$test_dir/metadata-delete-fail" "$test_dir/issue-list-fail" "$test_dir/apply-writes" "$test_dir/metadata-set-noop" "$test_dir"/reveal-on-delete-* "$test_dir"/fail-comments-on-delete-* "$test_dir/fail-set-on-delete" \
		"$test_dir"/wakeup-delete-fail* "$test_dir/wakeup-list-fail" "$test_dir/wakeup-list-reads" "$test_dir/wakeup-create-fail" "$test_dir/wakeup-deletes"
	cp "$test_dir/issue-list.base.json" "$test_dir/issue-list.json"
	cp "$test_dir/issue-list-all.base.json" "$test_dir/issue-list-all.json"
	: >"$test_dir/wakeups.jsonl"
	: >"$test_dir/dispatch-calls"
	: >"$test_dir/usage-reads"
	cp "$test_dir/rules.base.json" "$test_dir/rules.json"
	echo '[]' >"$test_dir/comments.json"
	cp "$test_dir/issue.json" "$test_dir/issue.current.json"
	cp "$test_dir/members.base.json" "$test_dir/members.json"
	cp "$test_dir/usage.base.json" "$test_dir/usage.json"
	echo 0 >"$test_dir/usage-status"
	echo 0 >"$test_dir/dispatch-status"
	rm -f "$test_dir/dispatch-out" "$test_dir/dispatch-near-out" "$test_dir/dispatch-near-status"
}
run() {
	status=0
	: >"$test_dir/dispatch-calls"
	: >"$test_dir/usage-reads"
	(cd "$test_dir" && bash monitor/squad-usage-wait pick test-issue "$@") >"$test_dir/out" 2>"$test_dir/err" || status=$?
}
expect_status() {
	[[ $status == "$1" ]] || { printf '終了コード %s を期待したが %s\n出力:\n%s\n標準エラー:\n%s\n' "$1" "$status" "$(<"$test_dir/out")" "$(<"$test_dir/err")" >&2; exit 1; }
}
expect_out() {
	[[ $(<"$test_dir/out") == "$1" ]] || { printf '期待した出力:\n%s\n実際の出力:\n%s\n標準エラー:\n%s\n' "$1" "$(<"$test_dir/out")" "$(<"$test_dir/err")" >&2; exit 1; }
}
wakeup_count() { jq -s length "$test_dir/wakeups.jsonl"; }
wakeup_ids() { jq -r '.[].id' "$test_dir/rules.json" | tr '\n' ' '; } # 今ある起こしの ID（一覧の順）
dispatch_calls() { paste -sd'|' "$test_dir/dispatch-calls"; }

wait_setup() { # リセットまでの秒数
	reset
	set_roster planner
	usage 90 $((now + $1)) 10 $((now + 100000)) 10 $((now + 100000)) true
}
wait_line() { # 工程 再開の時刻 待ち始め
	printf '使用率の待ち: %s を %s まで待つ。待ち始め: %s。上限に近い枠: Claude 週 90%%' "$1" "$(iso "$2")" "$(iso "$3")"
}
# 古い形の人間を呼ぶ行。流し直しの前のタスクに残っている行として、コメントに置く。
old_exceeded_line() { printf '使用率の待ち: planner の待ちが通算 24 時間を超える。待ち始め: %s' "$(iso "$1")"; }
# 新しい形の人間を呼ぶ行。引数は、待ち始め、再開の時刻。pick が終了 4 で出す行と、コメントに残る行の形。
exceeded_line() { printf '使用率の待ち: planner は %s まで待つと通算 24 時間を超える。待ち始め: %s。上限に近い枠: Claude 週 90%%' "$(iso "$2")" "$(iso "$1")"; }

answer_t=$((now - 600)) # 答えのコメントの時刻
run_answer() { # <工程> <判断> <答えのコメントの ID>。呼び出した実行は answer_caller（既定はリーダー）
	status=0
	: >"$test_dir/usage-reads"
	: >"$test_dir/posted-comments.jsonl"
	: >"$test_dir/metadata-calls.jsonl"
	(cd "$test_dir" && MULTICA_AGENT_ID=${answer_caller:-orchestrator} bash monitor/squad-usage-wait answer test-issue "$@") >"$test_dir/out" 2>"$test_dir/err" || status=$?
}
answer_setup() { # near（上限に近い。リセットまでの秒数を続ける）か free。工程は planner
	reset
	set_roster planner orchestrator
	if [[ $1 == near ]]; then
		usage 90 $((now + ${2:-7200})) 10 $((now + 100000)) 10 $((now + 100000)) true
	fi
	add_comment member member-test ans1 "$answer_t" '待つ'
}
answer_line() { # 判断 答えた時刻 期限 [上限に近い枠と使用率の説明]
	printf '使用率の答え: %s。答えた時刻: %s。期限: %s。スクワッド: squad-test。%s' "$1" "$(iso "$2")" "$(iso "$3")" "${4:-上限に近い枠: Claude 週 90%}"
}
posted_count() { jq -s length "$test_dir/posted-comments.jsonl"; }
metadata_count() { jq -s length "$test_dir/metadata-calls.jsonl"; }
expect_no_write() {
	[[ $(posted_count) == 0 && $(metadata_count) == 0 ]] || { echo '書かないはずが、コメントかマークを書いた' >&2; cat "$test_dir/posted-comments.jsonl" "$test_dir/metadata-calls.jsonl" >&2; exit 1; }
}
expect_none_line() { # 出力が「記録なし」の 1 行（書き込みは見ない）
	expect_status 0
	[[ $(<"$test_dir/out") == '使用率の答え: 記録なし。'* ]] || { printf '記録なしの行を期待したが:\n%s\n' "$(<"$test_dir/out")" >&2; exit 1; }
	[[ $(wc -l <"$test_dir/out" | tr -d ' ') == 1 ]]
}
expect_none() { # 出力が「記録なし」の 1 行で、何も書かない
	expect_none_line
	expect_no_write
}

this_task=$(jq -r .identifier "$test_dir/issue.json")
cancel_body() { # 取り消す記録のコメントの ID
	printf '使用率の答えの取り消し: %s。新しい答えのタスク: %s\n' "$1" "$this_task"
}

claude90='上限に近い枠: Claude 週 90%'
wait_answer_line() { # 工程 再開の時刻 待ち始め 期限 答えのタスクの識別子 上限に近い枠の説明
	printf '使用率の待ち: %s を %s まで待つ。待ち始め: %s。%s。人間の答えで待つ（期限 %s、答えのタスク %s）' "$1" "$(iso "$2")" "$(iso "$3")" "$6" "$(iso "$4")" "$5"
}
proceed_wait_line() { # 工程 再開の時刻 待ち始め 期限 答えのタスクの識別子 上限に近い枠の説明
	printf '使用率の待ち: %s を %s まで待つ。待ち始め: %s。%s。人間の答えで進めるが、頼める系統がないので待つ（期限 %s、答えのタスク %s）' "$1" "$(iso "$2")" "$(iso "$3")" "$6" "$(iso "$4")" "$5"
}
put_record() { # コメントの ID、コメントの時刻、行。マークは task-old に付く
	set_marked task-old:DEMO-1
	add_task_comment comments-task-old.json agent orchestrator "$1" "$2" "$3"
}
expect_wake_at() { # 起こしの時刻
	assert_jq --arg at "$(iso "$1")" '(.args | index("--at") as $k | .[$k + 1]) == $at' "$test_dir/wakeups.jsonl"
}

# 両系統の構成の下ごしらえ。dispatch-pick は、--allow-near なしでは終了 2、足したときは決めた出力と終了コードを返す。
proceed_dual() { # near-status near-out
	reset
	echo 2 >"$test_dir/dispatch-status"
	: >"$test_dir/dispatch-out"
	echo "$1" >"$test_dir/dispatch-near-status"
	printf '%s' "$2" >"$test_dir/dispatch-near-out"
	# Claude は週 85%（リセット 5 時間後）と 5 時間 90%（1 時間後）、Codex は週 82%（3 時間後）。
	usage 85 $((now + 18000)) 90 $((now + 3600)) 82 $((now + 10800)) true
}
near_out=$'役: codex-implementer\n振り分け: Codex（Claude は週の使用率が 80% 以上、Claude は 5 時間の枠が 80% 以上、Codex は週の使用率が 80% 以上。両方の系統が上限に近いので、人間の答えで選んだ）。Claude 週 85%・5 時間 90%、Codex 週 82%\n'
proceed_note_line() { # 期限 答えのタスクの識別子
	printf '人間の答えで進める（期限 %s、答えのタスク %s）' "$(iso "$1")" "$2"
}
both_near='上限に近い枠: Claude 週 85%・5 時間 90%、Codex 週 82%'
