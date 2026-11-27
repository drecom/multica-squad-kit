#!/usr/bin/env bash
# 連携なしの記録の共通の部品を、単体で確認する。
# 記録のパスの検査・作成・消去、pr_link_pull_request の PR_LINK_ALL_404、呼ぶ人間を決める関数、metadata の欄の約束を見る。
# 続けて、CLI と API と時計を差し替えて squad-pr-link を丸ごと流し、記録の読み書きと、失敗のあとの一覧の読み直しを通した動作を見る。
# 実際のタスク・PR・ホストの記録には触れない。記録の根は PR_LINK_STATE_ROOT で一時ディレクトリに向ける。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/pr-link-no-integration-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
source "$root/common/monitor/squad-cli-lib"
source "$root/common/monitor/squad-pr-link-lib"

fail() { echo "FAIL $*" >&2; exit 1; }
expect() { [[ $2 == "$3" ]] || fail "$1: 期待 [$3]、実際 [$2]"; }
mode_of() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }

project=proj-1
pr_url=https://github.com/Owner-A/Repo.Name/pull/12
export PR_LINK_STATE_ROOT=$test_dir/state

# --- 記録のパスの決め方と検査 ---
pr_link_record_locate "$project" "$pr_url"
expect 'パスはオーナーとリポジトリを小文字にする' "$PR_LINK_RECORD" "$PR_LINK_STATE_ROOT/proj-1/owner-a/repo.name"
expect 'パスの上のディレクトリ' "$PR_LINK_RECORD_DIR" "$PR_LINK_STATE_ROOT/proj-1/owner-a"
for bad in '' . .. 'a/b' '../x' 'a b' 'a;b' 'あ'; do
	if pr_link_record_part_ok "$bad"; then fail "部分 [$bad] を断る"; fi
done
for good in a A0 a_b a-b a.b .a; do
	pr_link_record_part_ok "$good" || fail "部分 [$good] を通す"
done
if pr_link_record_locate '..' "$pr_url" 2>/dev/null; then fail 'プロジェクトの ID の .. を断る'; fi
if pr_link_record_locate 'a/b' "$pr_url" 2>/dev/null; then fail 'プロジェクトの ID の / を断る'; fi
if pr_link_record_locate "$project" 'https://github.com/../repo/pull/1' 2>/dev/null; then fail 'オーナーの .. を断る'; fi
if pr_link_record_locate "$project" 'https://github.com/o/r%2Fx/pull/1' 2>/dev/null; then fail 'リポジトリの記号を断る'; fi
if pr_link_record_locate '' "$pr_url" 2>/dev/null; then fail '空のプロジェクトの ID を断る'; fi
err=$(pr_link_record_exists '..' "$pr_url" 2>&1 >/dev/null) && fail '断ったパスは記録なしとして 1 を返す'
expect '断ったときの標準エラーは 1 行' "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1
[[ ! -e $PR_LINK_STATE_ROOT ]] || fail '断ったときは何も作らない'

# --- 作成: 4 行・モード・一時ファイル ---
pr_link_record_exists "$project" "$pr_url" && fail '記録がなければ exists は 1'
[[ ! -e $PR_LINK_STATE_ROOT ]] || fail 'exists は何も作らない'
pr_link_record_create "$project" "$pr_url" TASK-7 || fail '記録を作る'
record=$PR_LINK_RECORD
expect '記録は 4 行' "$(wc -l <"$record" | tr -d ' ')" 4
expect '1 行目' "$(sed -n 1p "$record")" 'repository: owner-a/repo.name'
expect '2 行目' "$(sed -n 2p "$record")" "pr: $pr_url"
expect '3 行目' "$(sed -n 3p "$record")" 'task: TASK-7'
[[ $(sed -n 4p "$record") =~ ^記録した時刻:\ [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail '4 行目の形'
expect 'ファイルは 600' "$(mode_of "$record")" 600
expect 'プロジェクトのディレクトリは 700' "$(mode_of "$PR_LINK_RECORD_PROJECT_DIR")" 700
expect 'オーナーのディレクトリは 700' "$(mode_of "$PR_LINK_RECORD_DIR")" 700
pr_link_record_exists "$project" "$pr_url" || fail '作ったあとは exists が 0'
expect '作ったあとは記録だけが残る' "$(ls -A "$PR_LINK_RECORD_DIR")" repo.name
expect '作ったあとは一時ファイルを持たない' "${PR_LINK_RECORD_TMP:-}" ''

# --- 作成: すでにあるときは 2 を返し、記録を変えず、一時ファイルを残さない ---
before=$(cat "$record")
rc=0
pr_link_record_create "$project" "$pr_url" TASK-8 || rc=$?
expect 'すでにあれば 2' "$rc" 2
expect '記録は変わらない' "$(cat "$record")" "$before"
expect '一時ファイルが残らない' "$(ls -A "$PR_LINK_RECORD_DIR")" repo.name
expect '作れなかった実行は一時ファイルを持たない' "${PR_LINK_RECORD_TMP:-}" ''

# --- 別のプロジェクト・別のリポジトリの記録は、このリポジトリの記録ではない ---
pr_link_record_exists proj-2 "$pr_url" && fail '別のプロジェクトの記録を読まない'
pr_link_record_exists "$project" https://github.com/owner-a/other/pull/1 && fail '同じプロジェクトの別のリポジトリの記録を読まない'
pr_link_record_exists "$project" https://github.com/OWNER-A/REPO.NAME/pull/99 || fail '大文字小文字を区別せず同じ記録を読む'

# --- 用意と結ぶ: 結ぶまで記録は見えない ---
rm -f "$record"
pr_link_record_prepare "$project" "$pr_url" TASK-1 || fail '記録を用意する'
mine=$PR_LINK_RECORD_TMP
[[ -f $mine ]] || fail '用意した一時ファイルがある'
[[ ! -e $record ]] || fail '結ぶまで記録は見えない'
pr_link_record_exists "$project" "$pr_url" && fail '結ぶまで exists は 1'
pr_link_record_finish
[[ ! -e $mine ]] || fail '結ばずに finish すると一時ファイルが消える'
[[ ! -e $record ]] || fail '結ばずに finish しても記録は見えない'
expect '結ばなかったあとに何も残らない' "$(ls -A "$PR_LINK_RECORD_DIR")" ''
pr_link_record_prepare "$project" "$pr_url" TASK-1 || fail '記録を用意し直す'
mine=$PR_LINK_RECORD_TMP
pr_link_record_commit || fail '記録を結ぶ'
[[ -f $record ]] || fail '結ぶと記録が見える'
[[ ! -e $mine ]] || fail '結んだあとに一時ファイルが残らない'
expect '結んだあとに一時ファイルを持たない' "${PR_LINK_RECORD_TMP:-}" ''
# 先に別の実行が結んでいるとき: prepare は 2、結ぶ前に割り込まれたときの commit も 2。記録は変えない。
rm -f "$record"
pr_link_record_prepare "$project" "$pr_url" TASK-2 || fail '割り込まれる前に用意する'
printf 'other\n' >"$record"
rc=0
pr_link_record_commit || rc=$?
expect '結ぶ前に割り込まれると commit は 2' "$rc" 2
expect '別の実行の記録は変わらない' "$(cat "$record")" other
expect '割り込まれた実行は一時ファイルを残さない' "$(ls -A "$PR_LINK_RECORD_DIR")" repo.name
rc=0
pr_link_record_prepare "$project" "$pr_url" TASK-3 || rc=$?
expect '記録があるときの prepare は 2' "$rc" 2
expect '2 を返した prepare は一時ファイルを持たない' "${PR_LINK_RECORD_TMP:-}" ''
rm -f "$record"

# --- 消去: remove は記録があるときだけ消す ---
pr_link_record_create "$project" "$pr_url" TASK-1 || fail '消す記録を作る'
pr_link_record_remove "$project" "$pr_url" || fail '記録を消す'
[[ ! -e $record ]] || fail 'remove で記録が消える'
if pr_link_record_remove "$project" "$pr_url"; then fail '記録がなければ remove は 1'; fi

# --- 同時に作る: 1 つの実行だけが作れる ---
rm -rf -- "$PR_LINK_STATE_ROOT"
race=$test_dir/race
mkdir -p "$race"
for i in 1 2 3 4 5 6; do
	(
		rc=0
		pr_link_record_create "$project" "$pr_url" "TASK-$i" 2>/dev/null || rc=$?
		echo "$rc" >"$race/$i"
		pr_link_record_finish
	) &
done
wait
created=$(cat "$race"/* | grep -c '^0$' || true)
expect '同時に作れるのは 1 つ' "$created" 1
others=$(cat "$race"/* | grep -vc '^0$' || true)
expect '残りは作れない' "$others" 5
pr_link_record_locate "$project" "$pr_url"
expect '同時の作成のあと、ディレクトリには記録だけがある' "$(ls -A "$PR_LINK_RECORD_DIR")" repo.name
expect '記録は 4 行' "$(wc -l <"$PR_LINK_RECORD" | tr -d ' ')" 4

# --- シンボリックリンクと普通のファイルでないもの: ないものとして読み、書きも消しもしない ---
check_refused() {
	local label=$1 target=$2 err
	pr_link_record_locate "$project" "$pr_url"
	if err=$(pr_link_record_exists "$project" "$pr_url" 2>&1 >/dev/null); then fail "$label: exists は 1"; fi
	expect "$label: exists の標準エラーは 1 行" "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1
	if err=$(pr_link_record_remove "$project" "$pr_url" 2>&1 >/dev/null); then fail "$label: remove は 1"; fi
	expect "$label: remove の標準エラーは 1 行" "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1
	rc=0
	err=$(pr_link_record_create "$project" "$pr_url" TASK-9 2>&1 >/dev/null) || rc=$?
	expect "$label: create は 1" "$rc" 1
	expect "$label: create の標準エラーは 1 行" "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" 1
	expect "$label: 一時ファイルを持たない" "${PR_LINK_RECORD_TMP:-}" ''
	expect "$label: リンク先は変わらない" "$(ls -A "$target" | tr '\n' ' ')" "$target_before"
}
# 記録がシンボリックリンク
rm -rf -- "$PR_LINK_STATE_ROOT"
mkdir -p "$PR_LINK_STATE_ROOT/proj-1/owner-a" "$test_dir/elsewhere"
printf 'keep\n' >"$test_dir/elsewhere/file"
ln -s "$test_dir/elsewhere/file" "$PR_LINK_STATE_ROOT/proj-1/owner-a/repo.name"
target_before='file '
check_refused '記録がリンク' "$test_dir/elsewhere"
expect '記録のリンク先の中身は変わらない' "$(cat "$test_dir/elsewhere/file")" keep
[[ -L $PR_LINK_STATE_ROOT/proj-1/owner-a/repo.name ]] || fail 'リンクの記録は消さない'
# オーナーのディレクトリがシンボリックリンク
rm -rf -- "$PR_LINK_STATE_ROOT" "$test_dir/elsewhere"
mkdir -p "$PR_LINK_STATE_ROOT/proj-1" "$test_dir/elsewhere"
ln -s "$test_dir/elsewhere" "$PR_LINK_STATE_ROOT/proj-1/owner-a"
target_before=''
check_refused 'オーナーのディレクトリがリンク' "$test_dir/elsewhere"
# プロジェクトのディレクトリがシンボリックリンク
rm -rf -- "$PR_LINK_STATE_ROOT" "$test_dir/elsewhere"
mkdir -p "$PR_LINK_STATE_ROOT" "$test_dir/elsewhere"
ln -s "$test_dir/elsewhere" "$PR_LINK_STATE_ROOT/proj-1"
target_before=''
check_refused 'プロジェクトのディレクトリがリンク' "$test_dir/elsewhere"
# 記録の場所がディレクトリ
rm -rf -- "$PR_LINK_STATE_ROOT" "$test_dir/elsewhere"
mkdir -p "$PR_LINK_STATE_ROOT/proj-1/owner-a/repo.name" "$test_dir/elsewhere"
target_before=''
check_refused '記録がディレクトリ' "$PR_LINK_STATE_ROOT/proj-1/owner-a/repo.name"
# 壊れたリンクも断る
rm -rf -- "$PR_LINK_STATE_ROOT" "$test_dir/elsewhere"
mkdir -p "$PR_LINK_STATE_ROOT/proj-1/owner-a" "$test_dir/elsewhere"
ln -s "$test_dir/elsewhere/missing" "$PR_LINK_STATE_ROOT/proj-1/owner-a/repo.name"
target_before=''
check_refused '記録が壊れたリンク' "$test_dir/elsewhere"
[[ ! -e $test_dir/elsewhere/missing ]] || fail '壊れたリンクの先を作らない'
rm -rf -- "$PR_LINK_STATE_ROOT"

# --- PR_LINK_ALL_404: 時計と応答を差し替えて判定を見る ---
NOW=1000
SEQUENCE=()
CALL=0
date() { if [[ ${1-} == +%s ]]; then echo "$NOW"; else command date "$@"; fi; }
sleep() { NOW=$((NOW + $1)); }
pr_link_check_api_env() { return 0; }
multica() { return 0; }
# 応答は「状態コード:かかる秒数」の並び。T:秒数 は通信の失敗。尽きたら最後の応答を繰り返す。
pr_link_request_once() {
	local entry index=$CALL
	((index < ${#SEQUENCE[@]})) || index=$((${#SEQUENCE[@]} - 1))
	entry=${SEQUENCE[$index]}
	CALL=$((CALL + 1))
	NOW=$((NOW + ${entry#*:}))
	PR_LINK_STATUS=${entry%%:*}
	if [[ $PR_LINK_STATUS == T ]]; then
		PR_LINK_STATUS=''
		return 1
	fi
}
run_pull() {
	local label=$1 want_rc=$2 want_not_found=$3 want_all_404=$4 want_calls=$5 metadata=${6:-'{}'}
	shift 5 || true
	local rc=0
	NOW=1000
	CALL=0
	pr_link_pull_request task-id "$pr_url" "$metadata" || rc=$?
	expect "$label: 戻り値" "$rc" "$want_rc"
	expect "$label: PR_LINK_NOT_FOUND" "$PR_LINK_NOT_FOUND" "$want_not_found"
	expect "$label: PR_LINK_ALL_404" "$PR_LINK_ALL_404" "$want_all_404"
	[[ -z $want_calls ]] || expect "$label: API を呼んだ回数" "$CALL" "$want_calls"
}
# 404 が 120 秒続き、次の試みの前に期限を過ぎる
SEQUENCE=(404:0)
run_pull '404 だけが続き、次の試みの前に期限' 1 1 1 12
# 期限の直前の応答が 404（遅れて返った 404）
SEQUENCE=(404:0 404:0 404:0 404:0 404:0 404:0 404:0 404:0 404:0 404:0 404:0 404:15)
run_pull '期限を過ぎて返った 404' 1 1 1 12
# 最初の応答が遅れた 404
SEQUENCE=(404:130)
run_pull '最初の応答が遅れた 404' 1 1 1 1
# 期限の直前の応答が通信の失敗・500・遅れた 200
SEQUENCE=(404:0 404:0 404:0 404:0 404:0 404:0 404:0 404:0 404:0 404:0 404:0 T:15)
run_pull '期限を過ぎた通信の失敗' 1 1 0 12
SEQUENCE=(404:0 404:0 404:0 404:0 404:0 404:0 404:0 404:0 404:0 404:0 404:0 500:15)
run_pull '期限を過ぎた 500' 1 1 0 12
SEQUENCE=(404:0 404:0 404:0 404:0 404:0 404:0 404:0 404:0 404:0 404:0 404:0 200:15)
run_pull '期限を過ぎた 200' 1 1 0 12
SEQUENCE=(T:130)
run_pull '最初の応答が遅れた通信の失敗' 1 1 0 1
SEQUENCE=(200:130)
run_pull '最初の応答が遅れた 200' 1 1 0 1
# 期限の前に終わるもの
SEQUENCE=(404:0 500:0)
run_pull '404 のあとの 500' 1 0 0 2
SEQUENCE=(404:0 T:0)
run_pull '404 のあとの通信の失敗' 1 0 0 2
SEQUENCE=(T:0)
run_pull '最初の通信の失敗' 1 0 0 1
SEQUENCE=(500:0)
run_pull '最初の 500' 1 0 0 1
SEQUENCE=(404:0 404:0 200:0)
run_pull '404 のあとの 200 で紐付く' 0 0 0 3
SEQUENCE=(200:0)
run_pull '最初の 200 で紐付く' 0 0 0 1
# 呼ぶ前に決まるもの
SEQUENCE=(404:0)
run_pull 'pr_url が書かれている' 0 0 0 0 '{"pr_url":"https://github.com/owner-a/repo.name/pull/12"}'
run_pull 'repository が違う' 1 0 0 0 '{"repository":"owner-a/other"}'
# 前の呼び出しの値を引きずらない
SEQUENCE=(404:0)
run_pull '404 だけが続く' 1 1 1 12
SEQUENCE=(200:0)
run_pull '直前に 1 だった ALL_404 は次の呼び出しで 0 に戻る' 0 0 0 1
unset -f date sleep multica pr_link_request_once pr_link_check_api_env
source "$root/common/monitor/squad-pr-link-lib"

# --- 呼ぶ人間を決める関数 ---
test_members='[{"user_id":"u-1","name":"Human One"},{"user_id":"u-2","name":"Human Two"}]'
squad_cli_read() {
	[[ $1 == member-list ]] || fail "member-list 以外を読んだ: $1"
	[[ -n ${MEMBER_FAIL:-} ]] && return 1
	printf '%s\n' "$test_members"
}
MEMBER_FAIL=
rc=0
squad_cli_human_of_squad '{"creator_id":"u-2"}' || rc=$?
expect '決められる: 戻り値' "$rc" 0
expect '決められる: ID' "$HUMAN_ID" u-2
expect '決められる: 名前' "$HUMAN_NAME" 'Human Two'
expect '決められる: 理由は空' "$HUMAN_REASON" ''
rc=0
squad_cli_human_of_squad '{"name":"x"}' || rc=$?
expect 'creator_id がない: 戻り値' "$rc" 1
expect 'creator_id がない: ID は空' "$HUMAN_ID" ''
[[ $HUMAN_REASON == *creator_id* ]] || fail 'creator_id がない: 理由に creator_id'
rc=0
squad_cli_human_of_squad 'not json' || rc=$?
expect '読めないスクワッド: 戻り値' "$rc" 1
[[ -n $HUMAN_REASON ]] || fail '読めないスクワッド: 理由がある'
rc=0
squad_cli_human_of_squad '{"creator_id":"u-9"}' || rc=$?
expect '名簿にいない: 戻り値' "$rc" 1
expect '名簿にいない: 名前は空' "$HUMAN_NAME" ''
[[ -n $HUMAN_REASON ]] || fail '名簿にいない: 理由がある'
MEMBER_FAIL=1
rc=0
squad_cli_human_of_squad '{"creator_id":"u-1"}' || rc=$?
expect '名簿を読めない: 戻り値' "$rc" 1
[[ -n $HUMAN_REASON ]] || fail '名簿を読めない: 理由がある'
# 失敗しても呼び出し元を止めない（dfail を呼ばない）。直前の結果を引きずらない。
MEMBER_FAIL=
squad_cli_human_of_squad '{"creator_id":"u-1"}'
expect '成功のあとの名前' "$HUMAN_NAME" 'Human One'
squad_cli_human_of_squad '{}' || true
expect '失敗のあとに前の名前を残さない' "$HUMAN_NAME" ''
unset -f squad_cli_read
source "$root/common/monitor/squad-cli-lib"

# --- metadata の欄の約束 ---
contracts=$(squad_cli_contracts)
for field in metadata.pr_link_no_integration metadata.pr_link_tried_at project_id; do
	got=$(jq -r --arg p "$field" '.entries["issue-get"].fields[] | select(.path == $p) | "\(.class) \(.nullable)"' <<<"$contracts")
	expect "issue-get の $field は省略可能" "$got" 'optional true'
done

# --- squad-pr-link: 記録の読み書きを通した動作 ---
# CLI と API と時計を差し替えて、スクリプトを丸ごと流す。実際のタスク・PR・ホストの記録には触れない。
e2e=$test_dir/e2e
export PR_LINK_TEST_DIR=$e2e PR_LINK_TEST_ROOT=$root
script=$root/common/monitor/squad-pr-link
mkdir -p "$e2e/bin" "$e2e/work/tmp"
for cmd in bash dirname jq tr cat python3 mkdir mktemp rm sed ln chmod wc; do
	ln -s "$(command -v "$cmd")" "$e2e/bin/$cmd"
done
squad_cli_contracts >"$e2e/contracts.json"
cat >"$e2e/bin/multica" <<'MOCK'
#!/bin/bash
set -euo pipefail
dir=$PR_LINK_TEST_DIR
stub_args=("$@")
stub() { recorded=1; python3 "$PR_LINK_TEST_ROOT/tests/cli-stub.py" multica "$dir" multica "$@" -- ${stub_args[@]+"${stub_args[@]}"}; }
if [[ ${1-} == version ]]; then stub - record; echo 'multica fixture-version'; exit 0; fi
recorded=
trap '[[ -n $recorded ]] || stub multica.jsonl record' EXIT
if [[ $1 == issue && $2 == get ]]; then
	[[ $3 == TASK-7 && $4 == --output && $5 == json ]]
	stub multica.jsonl emit issue-get "$dir/issue.json"
elif [[ $1 == issue && $2 == metadata && $3 == set ]]; then
	[[ $4 == task-id && $5 == --key && $7 == --value && $9 == --type && ${10} == string ]]
	case $6 in pr_url | pr_link_pending | pr_link_no_integration) ;; *) exit 99 ;; esac
	# 欄を書く時点で記録が見えていたかを残す。pr_url を書く前に記録が見えると、書けなかったときに連携なしだけが残る。
	if [[ $6 == pr_url && -f $dir/watch-record && -e $(<"$dir/watch-record") ]]; then touch "$dir/record-visible"; fi
	if [[ -f $dir/fail-$6 ]]; then echo "$MULTICA_TOKEN" >&2; exit 1; fi
	jq --arg key "$6" --arg value "$8" '.metadata[$key] = $value' "$dir/issue.json" >"$dir/next.json"
	/bin/mv "$dir/next.json" "$dir/issue.json"
elif [[ $1 == issue && $2 == pull-requests ]]; then
	[[ $3 == TASK-7 && $4 == --output && $5 == json ]]
	stub multica.jsonl record
	[[ ! -f $dir/fail-pulls ]] || { echo "$MULTICA_TOKEN" >&2; exit 1; }
	cat "$dir/pulls.json"
else
	exit 99
fi
MOCK
cat >"$e2e/bin/curl" <<'MOCK'
#!/bin/bash
set -euo pipefail
dir=$PR_LINK_TEST_DIR
python3 "$PR_LINK_TEST_ROOT/tests/cli-stub.py" none "$dir" curl curl.jsonl record -- "$@"
cat >/dev/null
calls=$(<"$dir/curl-count")
args=("$@")
max_time=0
for ((i = 0; i < ${#args[@]}; i++)); do
	if [[ ${args[i]} == --max-time ]]; then max_time=${args[i+1]}; fi
done
duration=$(jq -r --argjson i "$calls" '.[ $i ] // .[-1]' "$dir/durations.json")
echo "$((calls + 1))" >"$dir/curl-count"
echo "$(($(<"$dir/now") + duration))" >"$dir/now"
if [[ -f $dir/transport-fail-from ]] && (( calls >= $(<"$dir/transport-fail-from") )); then exit 7; fi
if (( duration >= max_time )) && [[ ! -f $dir/ignore-timeout ]]; then printf '000'; exit 28; fi
jq -r --argjson i "$calls" '.[ $i ] // .[-1]' "$dir/statuses.json"
MOCK
cat >"$e2e/bin/date" <<'MOCK'
#!/bin/bash
set -euo pipefail
if [[ $* == +%s ]]; then cat "$PR_LINK_TEST_DIR/now"; elif [[ $* == '-u +%Y-%m-%dT%H:%M:%SZ' ]]; then echo 2026-01-02T03:04:05Z; else exit 99; fi
MOCK
cat >"$e2e/bin/sleep" <<'MOCK'
#!/bin/bash
set -euo pipefail
dir=$PR_LINK_TEST_DIR
echo "$1" >>"$dir/sleeps"
echo "$(($(<"$dir/now") + $1))" >"$dir/now"
# 待っているあいだに、別の実行が記録を作った場面を作る。
if [[ -f $dir/rival-record && ! -e $(<"$dir/rival-record") ]]; then
	mkdir -p "$(dirname "$(<"$dir/rival-record")")"
	printf 'repository: rival\n' >"$(<"$dir/rival-record")"
fi
MOCK
chmod +x "$e2e/bin/multica" "$e2e/bin/curl" "$e2e/bin/date" "$e2e/bin/sleep"
e2e_url=https://github.com/Example/Template/pull/33
e2e_record=$PR_LINK_STATE_ROOT/fixture-id-000036/example/template
e2e_notice='example/template を、このプロジェクトでは GitHub 連携なしとして扱います。サーバーが 120 秒待っても PR を見つけなかったためです。このあとの PR では紐付けを待たず、紐付けの警告と依頼を出さず、マージ待ちの見張りがマージを確認してタスクを done にします。連携しているはずなら、ワークスペースの設定のコードの画面で example/template がつながっていることを確認してください。このリポジトリの PR が 1 つでも紐付けば、自動で連携ありの扱いに戻ります。'
e2e_reset() {
	python3 "$root/tests/multica-fixture.py" "$e2e" base issue-get |
		jq '. + {id:"task-id",identifier:"TASK-7"} | .metadata.repository="example/template" | del(.metadata.pr_url)' >"$e2e/issue.json"
	printf '[404]\n' >"$e2e/statuses.json"
	printf '[0]\n' >"$e2e/durations.json"
	printf '{"pull_requests":[]}\n' >"$e2e/pulls.json"
	echo 1000 >"$e2e/now"
	echo 0 >"$e2e/curl-count"
	: >"$e2e/multica.jsonl"
	: >"$e2e/curl.jsonl"
	: >"$e2e/sleeps"
	rm -rf -- "$e2e"/fail-* "$e2e/record-visible" "$e2e/watch-record" "$e2e/transport-fail-from" "$e2e/ignore-timeout" "$e2e/rival-record" "$PR_LINK_STATE_ROOT"
}
e2e_run() {
	local expected=$1 status=0
	shift
	(cd "$e2e/work"; PATH="$e2e/bin" MULTICA_TOKEN=${E2E_TOKEN-e2e-secret} MULTICA_SERVER_URL=https://multica.invalid/ /bin/bash "$script" "$@") \
		>"$e2e/out" 2>"$e2e/err" || status=$?
	[[ $status == "$expected" ]] || { cat "$e2e/out" "$e2e/err" >&2; fail "終了コード $status、期待 $expected"; }
}
e2e_field() { jq -r --arg key "$1" '.metadata[$key] // "なし"' "$e2e/issue.json"; }
e2e_warn_not_found() {
	grep -qF "タスク TASK-7 に PR $e2e_url を紐付けられませんでした" "$e2e/err" || fail '今と同じ警告がない'
	[[ ! -s $e2e/out ]] || fail '標準出力が空でない'
}
e2e_no_record() { [[ ! -e $PR_LINK_STATE_ROOT ]] || [[ -z $(find "$PR_LINK_STATE_ROOT" -type f 2>/dev/null) ]] || fail '記録ができている'; }
# 一覧の読み取りの呼び出しの回数。
e2e_pulls_calls() { grep -c '"pull-requests"' "$e2e/multica.jsonl" || true; }
# タスクの PR の一覧を、PR が 1 件ある形にする。第 1 引数は html_url、第 2 引数は link_source（なければ付けない）。
e2e_list_pr() {
	jq -n --arg url "$1" --arg source "${2-}" --argjson has_source "$([[ $# -ge 2 ]] && echo true || echo false)" \
		'{pull_requests: [{html_url: $url} + (if $has_source then {link_source: $source} else {} end)]}' >"$e2e/pulls.json"
}
e2e_no_tmp() { [[ -z $(find "$PR_LINK_STATE_ROOT" -name '.record.*' 2>/dev/null) ]] || fail '一時ファイルが残った'; }

# 記録がなく、404 だけが 120 秒続く: 記録が 4 行でき、3 つの欄が書かれ、知らせの 2 行で 0 で終わる。
e2e_reset
e2e_run 0 TASK-7 "$e2e_url"
expect '連携なしにした: 1 行目' "$(sed -n 1p "$e2e/out")" "連携なしにしました: TASK-7 $e2e_url"
expect '連携なしにした: 2 行目' "$(sed -n 2p "$e2e/out")" "$e2e_notice"
expect '連携なしにした: 行数' "$(wc -l <"$e2e/out" | tr -d ' ')" 2
[[ ! -s $e2e/err ]] || fail '連携なしにした: 標準エラーが空でない'
expect '120 秒待った' "$(<"$e2e/curl-count")" 12
expect '記録は 4 行' "$(wc -l <"$e2e_record" | tr -d ' ')" 4
expect '記録の中身' "$(cat "$e2e_record")" "$(printf 'repository: example/template\npr: %s\ntask: TASK-7\n記録した時刻: 2026-01-02T03:04:05Z' "$e2e_url")"
expect '記録のモード' "$(mode_of "$e2e_record")" 600
for key in pr_url pr_link_pending pr_link_no_integration; do expect "$key" "$(e2e_field "$key")" "$e2e_url"; done
e2e_no_tmp

# 404 のあとに 500・通信の失敗が返った、または期限を過ぎてから 500・通信の失敗・200 が返ったときは、記録ができず、今と同じ警告で 1 で終わる。
for scene in early-500 early-transport late-500 late-transport late-200; do
	e2e_reset
	case $scene in
	early-500) printf '[404,500]\n' >"$e2e/statuses.json"; reason='応答の状態コード 500' ;;
	early-transport) printf '[404,404]\n' >"$e2e/statuses.json"; echo 1 >"$e2e/transport-fail-from"; reason=通信に失敗した ;;
	late-500) printf '[404,404,404,500]\n' >"$e2e/statuses.json"; reason='120 秒待った' ;;
	late-transport) printf '[404,404,404,404]\n' >"$e2e/statuses.json"; echo 3 >"$e2e/transport-fail-from"; reason='120 秒待った' ;;
	late-200) printf '[404,404,404,200]\n' >"$e2e/statuses.json"; reason='120 秒待った' ;;
	esac
	if [[ $scene == late-* ]]; then
		printf '[29,29,29,4]\n' >"$e2e/durations.json"
		touch "$e2e/ignore-timeout"
	fi
	e2e_run 1 TASK-7 "$e2e_url"
	e2e_warn_not_found
	grep -qF "（$reason" "$e2e/err" || { cat "$e2e/err" >&2; fail "$scene: 理由が違う"; }
	e2e_no_record
	expect "$scene: 記録の欄" "$(e2e_field pr_link_no_integration)" なし
	expect "$scene: pr_url" "$(e2e_field pr_url)" なし
	expect "$scene: マーク" "$(e2e_field pr_link_pending)" "$e2e_url"
done

# 記録を作ったあと、マークの片方を書けなくても 0 で終わり、書けなかった欄は空のまま。
for key in pr_link_pending pr_link_no_integration; do
	e2e_reset
	touch "$e2e/fail-$key"
	e2e_run 0 TASK-7 "$e2e_url"
	[[ -f $e2e_record ]] || fail "$key を書けなくても記録は残る"
	expect "$key を書けない: 書けなかった欄" "$(e2e_field "$key")" なし
	expect "$key を書けない: pr_url" "$(e2e_field pr_url)" "$e2e_url"
	expect "$key を書けない: 1 行目" "$(sed -n 1p "$e2e/out")" "連携なしにしました: TASK-7 $e2e_url"
	[[ ! -s $e2e/err ]] || fail "$key を書けない: 標準エラーが空でない"
done

# 待っているあいだに別の実行が記録を作った: 知らせは出さず、紐付けていません（連携なし）で 0 で終わり、先の記録は残る。
e2e_reset
echo "$e2e_record" >"$e2e/rival-record"
e2e_run 0 TASK-7 "$e2e_url"
expect '別の実行が先: 出力' "$(cat "$e2e/out")" "紐付けていません（連携なし）: TASK-7 $e2e_url"
[[ ! -s $e2e/err ]] || fail '別の実行が先: 標準エラーが空でない'
expect '別の実行が先: 記録は先の実行のもの' "$(cat "$e2e_record")" 'repository: rival'
for key in pr_url pr_link_pending pr_link_no_integration; do expect "別の実行が先: $key" "$(e2e_field "$key")" "$e2e_url"; done
e2e_no_tmp
# その実行が pr_url を書けないときも、先の記録は残る。
e2e_reset
echo "$e2e_record" >"$e2e/rival-record"
touch "$e2e/fail-pr_url"
e2e_run 1 TASK-7 "$e2e_url"
e2e_warn_not_found
expect '別の実行が先で pr_url を書けない: 記録は先の実行のもの' "$(cat "$e2e_record")" 'repository: rival'
e2e_no_tmp

# 記録は pr_url を書いたあとに見えるようにする: pr_url を書く時点では見えず、書いたあとに見える。
e2e_reset
echo "$e2e_record" >"$e2e/watch-record"
e2e_run 0 TASK-7 "$e2e_url"
[[ ! -e $e2e/record-visible ]] || fail 'pr_url を書く前に記録が見えた'
[[ -f $e2e_record ]] || fail '書いたあとは記録が見える'
e2e_no_tmp

# 待っているあいだに別の実行が記録を作り、そのあとにこの実行が紐付いた: 連携ありの PR なので、記録を消す。
e2e_reset
printf '[404,200]\n' >"$e2e/statuses.json"
echo "$e2e_record" >"$e2e/rival-record"
e2e_run 0 TASK-7 "$e2e_url"
expect '紐付いた: 出力' "$(cat "$e2e/out")" "紐付けました: TASK-7 $e2e_url"
expect '紐付いた: pr_url' "$(e2e_field pr_url)" "$e2e_url"
[[ ! -e $e2e_record ]] || fail '紐付いたあとに記録が残った'
e2e_no_tmp

# 記録を作った実行が pr_url を書けない: 記録は結ばれず、今と同じ警告で 1 で終わる。
e2e_reset
touch "$e2e/fail-pr_url"
e2e_run 1 TASK-7 "$e2e_url"
e2e_warn_not_found
e2e_no_record
e2e_no_tmp
expect 'pr_url を書けない: マーク' "$(e2e_field pr_link_pending)" "$e2e_url"
expect 'pr_url を書けない: 連携なしの欄' "$(e2e_field pr_link_no_integration)" なし

# 記録を書けない（記録の根が普通のファイル）: 今と同じ警告で 1 で終わる。
e2e_reset
: >"$e2e/not-a-directory"
PR_LINK_STATE_ROOT=$e2e/not-a-directory e2e_run 1 TASK-7 "$e2e_url"
e2e_warn_not_found
expect '記録を書けない: pr_url' "$(e2e_field pr_url)" なし
expect '記録を書けない: 連携なしの欄' "$(e2e_field pr_link_no_integration)" なし

# 404 だけでない失敗・トークンがない・作業先が違う・作業先がない・プロジェクトがない: 記録ができず、出力は今と同じ。
for scene in status500 token other-repository no-repository no-project; do
	e2e_reset
	case $scene in
	status500) printf '[500]\n' >"$e2e/statuses.json" ;;
	other-repository) jq '.metadata.repository = "other/service"' "$e2e/issue.json" >"$e2e/next.json" && mv "$e2e/next.json" "$e2e/issue.json" ;;
	no-repository) jq 'del(.metadata.repository)' "$e2e/issue.json" >"$e2e/next.json" && mv "$e2e/next.json" "$e2e/issue.json" ;;
	no-project) jq 'del(.project_id)' "$e2e/issue.json" >"$e2e/next.json" && mv "$e2e/next.json" "$e2e/issue.json" ;;
	esac
	if [[ $scene == token ]]; then E2E_TOKEN='' e2e_run 1 TASK-7 "$e2e_url"; else e2e_run 1 TASK-7 "$e2e_url"; fi
	[[ ! -s $e2e/out ]] || fail "$scene: 標準出力が空でない"
	grep -qF "タスク TASK-7 に PR $e2e_url を紐付けられませんでした" "$e2e/err" || fail "$scene: 今と同じ警告がない"
	e2e_no_record
	expect "$scene: 連携なしの欄" "$(e2e_field pr_link_no_integration)" なし
	expect "$scene: pr_url" "$(e2e_field pr_url)" なし
done

# 記録があるとき: 待たず、API を 1 回だけ呼ぶ。404・通信の失敗・トークンがないでも、警告なしで 0 で終わり、3 つの欄を書く。
for scene in 404 transport token; do
	e2e_reset
	mkdir -p "$(dirname "$e2e_record")" && printf 'repository: example/template\n' >"$e2e_record"
	if [[ $scene == transport ]]; then echo 0 >"$e2e/transport-fail-from"; fi
	if [[ $scene == token ]]; then E2E_TOKEN='' e2e_run 0 TASK-7 "$e2e_url"; else e2e_run 0 TASK-7 "$e2e_url"; fi
	expect "記録あり $scene: 出力" "$(cat "$e2e/out")" "紐付けていません（連携なし）: TASK-7 $e2e_url"
	[[ ! -s $e2e/err ]] || fail "記録あり $scene: 標準エラーが空でない"
	expect "記録あり $scene: API の呼び出し" "$(<"$e2e/curl-count")" "$([[ $scene == token ]] && echo 0 || echo 1)"
	[[ ! -s $e2e/sleeps ]] || fail "記録あり $scene: 待った"
	for key in pr_url pr_link_pending pr_link_no_integration; do expect "記録あり $scene: $key" "$(e2e_field "$key")" "$e2e_url"; done
	[[ -f $e2e_record ]] || fail "記録あり $scene: 記録が消えた"
done
# 記録があり、API が 200: 紐付けて、記録を消す。
e2e_reset
mkdir -p "$(dirname "$e2e_record")" && printf 'repository: example/template\n' >"$e2e_record"
printf '[200]\n' >"$e2e/statuses.json"
e2e_run 0 TASK-7 "$e2e_url"
expect '記録あり 200: 出力' "$(cat "$e2e/out")" "紐付けました: TASK-7 $e2e_url"
[[ ! -e $e2e_record ]] || fail '記録あり 200: 記録が消えていない'
expect '記録あり 200: pr_url' "$(e2e_field pr_url)" "$e2e_url"
expect '記録あり 200: 連携なしの欄は書かない' "$(e2e_field pr_link_no_integration)" なし
# 記録があり、pr_url を書けない: 今と同じ警告で 1 で終わり、記録は変えない。
for status in 404 200; do
	e2e_reset
	mkdir -p "$(dirname "$e2e_record")" && printf 'repository: example/template\n' >"$e2e_record"
	printf '[%s]\n' "$status" >"$e2e/statuses.json"
	touch "$e2e/fail-pr_url"
	e2e_run 1 TASK-7 "$e2e_url"
	[[ ! -s $e2e/out ]] || fail "記録ありで pr_url を書けない($status): 標準出力が空でない"
	grep -qF "タスク TASK-7 に PR $e2e_url を紐付けられませんでした" "$e2e/err" || fail "記録ありで pr_url を書けない($status): 警告がない"
	expect "記録ありで pr_url を書けない($status): 記録" "$(cat "$e2e_record")" 'repository: example/template'
done
# 記録があっても、pr_url がすでにあれば API を呼ばず、今と同じ行を出す。
e2e_reset
mkdir -p "$(dirname "$e2e_record")" && printf 'repository: example/template\n' >"$e2e_record"
jq --arg url "$e2e_url" '.metadata.pr_url = $url' "$e2e/issue.json" >"$e2e/next.json" && mv "$e2e/next.json" "$e2e/issue.json"
e2e_run 0 TASK-7 "$e2e_url"
[[ $(cat "$e2e/out") == "紐付けていません: TASK-7 ${e2e_url}（metadata に pr_url があるため、API を呼びませんでした。紐付いているかは multica issue pull-requests で確認してください）" ]] || fail 'pr_url がある: 今と同じ行'
expect 'pr_url がある: API を呼ばない' "$(<"$e2e/curl-count")" 0
[[ -f $e2e_record ]] || fail 'pr_url がある: 記録を変えない'

# 別のプロジェクトの記録と、同じプロジェクトの別のリポジトリの記録は、記録がないものとして 120 秒まで待つ。自分の記録を作り、ほかの記録は変えない。
for other in other-project other-repository; do
	e2e_reset
	if [[ $other == other-project ]]; then other_record=$PR_LINK_STATE_ROOT/another-project/example/template; else other_record=$PR_LINK_STATE_ROOT/fixture-id-000036/example/another; fi
	mkdir -p "$(dirname "$other_record")" && printf 'repository: other\n' >"$other_record"
	e2e_run 0 TASK-7 "$e2e_url"
	expect "$other: 120 秒待った" "$(<"$e2e/curl-count")" 12
	expect "$other: 出力" "$(sed -n 1p "$e2e/out")" "連携なしにしました: TASK-7 $e2e_url"
	expect "$other: ほかの記録は変えない" "$(cat "$other_record")" 'repository: other'
	[[ -f $e2e_record ]] || fail "$other: 自分の記録を作る"
done
# 120 秒のうちに 200 になれば、記録を作らない。
e2e_reset
printf '[404,404,200]\n' >"$e2e/statuses.json"
e2e_run 0 TASK-7 "$e2e_url"
expect '待って紐付いた: 出力' "$(cat "$e2e/out")" "紐付けました: TASK-7 $e2e_url"
e2e_no_record

# シンボリックリンクと、パスに使えない文字: 記録を読まず書かず、標準エラーの理由は警告の前に 1 行だけ出す。リンク先は書き換えない。
e2e_reset
mkdir -p "$PR_LINK_STATE_ROOT/fixture-id-000036/example" "$e2e/elsewhere"
ln -s "$e2e/elsewhere" "$e2e_record"
e2e_run 1 TASK-7 "$e2e_url"
e2e_warn_not_found
expect 'リンクの記録: 理由の行' "$(grep -c 'シンボリックリンク' "$e2e/err" | tr -d ' ')" 1
expect '120 秒待った（リンクの記録）' "$(<"$e2e/curl-count")" 12
[[ -z $(ls -A "$e2e/elsewhere") ]] || fail 'リンク先に書いた'
e2e_reset
mkdir -p "$e2e/elsewhere" "$PR_LINK_STATE_ROOT/fixture-id-000036"
ln -s "$e2e/elsewhere" "$PR_LINK_STATE_ROOT/fixture-id-000036/example"
e2e_run 1 TASK-7 "$e2e_url"
e2e_warn_not_found
[[ -z $(ls -A "$e2e/elsewhere") ]] || fail 'リンクのディレクトリの先に書いた'
for bad_project in '..' 'a/b'; do
	e2e_reset
	jq --arg project "$bad_project" '.project_id = $project' "$e2e/issue.json" >"$e2e/next.json" && mv "$e2e/next.json" "$e2e/issue.json"
	e2e_run 1 TASK-7 "$e2e_url"
	e2e_warn_not_found
	e2e_no_record
	[[ ! -e $e2e/state/example ]] || fail "プロジェクトの ID [$bad_project] で根の外に書いた"
done

# 失敗のあとの一覧の読み直し: 一覧に PR があれば、警告も記録もマークもなしに、紐付いていた行を出して 0 で終わる。
e2e_listed_line() { printf '紐付いていました: TASK-7 %s 紐付け方: %s' "$e2e_url" "$1"; }
e2e_listed_check() {
	local label=$1 source=$2
	expect "$label: 出力" "$(cat "$e2e/out")" "$(e2e_listed_line "$source")"
	[[ ! -s $e2e/err ]] || { cat "$e2e/err" >&2; fail "$label: 標準エラーが空でない"; }
	expect "$label: pr_url" "$(e2e_field pr_url)" "$e2e_url"
	expect "$label: マークは書かない" "$(e2e_field pr_link_pending)" なし
	expect "$label: 連携なしの欄は書かない" "$(e2e_field pr_link_no_integration)" なし
	expect "$label: 一覧は 1 回だけ読む" "$(e2e_pulls_calls)" 1
}
# 記録がなく、120 秒のあいだ 404 で、一覧に PR がある: 記録ができず、紐付け方に link_source を出す。
e2e_reset
e2e_list_pr "$e2e_url" title
e2e_run 0 TASK-7 "$e2e_url"
e2e_listed_check '記録なし 404 で一覧に PR' title
expect '記録なし 404 で一覧に PR: 120 秒待った' "$(<"$e2e/curl-count")" 12
e2e_no_record
# 一覧の PR の URL は、大文字小文字と末尾の部分を区別せず、link-check と同じに比べる。
e2e_reset
e2e_list_pr "https://GitHub.com/example/template/pull/33/files" manual
e2e_run 0 TASK-7 "$e2e_url"
e2e_listed_check '一覧の URL の形が違う' manual
# 記録がなく、404 のあとに 500・通信の失敗、期限を過ぎてから 200 が返って、一覧に PR がある: 同じ行で 0 で終わる。
for scene in status500 early-transport late-200 token; do
	e2e_reset
	e2e_list_pr "$e2e_url" title
	case $scene in
	status500) printf '[500]\n' >"$e2e/statuses.json" ;;
	early-transport) printf '[404,404]\n' >"$e2e/statuses.json"; echo 1 >"$e2e/transport-fail-from" ;;
	late-200)
		printf '[404,404,404,200]\n' >"$e2e/statuses.json"
		printf '[29,29,29,4]\n' >"$e2e/durations.json"
		touch "$e2e/ignore-timeout"
		;;
	esac
	if [[ $scene == token ]]; then E2E_TOKEN='' e2e_run 0 TASK-7 "$e2e_url"; else e2e_run 0 TASK-7 "$e2e_url"; fi
	e2e_listed_check "記録なし $scene で一覧に PR" title
	e2e_no_record
done
# 作業先がない（metadata に repository がない）タスクも、読み直す。
e2e_reset
jq 'del(.metadata.repository)' "$e2e/issue.json" >"$e2e/next.json" && mv "$e2e/next.json" "$e2e/issue.json"
e2e_list_pr "$e2e_url" title
e2e_run 0 TASK-7 "$e2e_url"
expect '作業先がない: 出力' "$(cat "$e2e/out")" "$(e2e_listed_line title)"
expect '作業先がない: pr_url' "$(e2e_field pr_url)" "$e2e_url"
# 記録があり、API が 404・通信の失敗・トークンなしで、一覧に PR がある: 記録が消え、同じ行で 0 で終わる。待たず、API は多くて 1 回。
for scene in 404 transport token; do
	e2e_reset
	mkdir -p "$(dirname "$e2e_record")" && printf 'repository: example/template\n' >"$e2e_record"
	e2e_list_pr "$e2e_url" title
	if [[ $scene == transport ]]; then echo 0 >"$e2e/transport-fail-from"; fi
	if [[ $scene == token ]]; then E2E_TOKEN='' e2e_run 0 TASK-7 "$e2e_url"; else e2e_run 0 TASK-7 "$e2e_url"; fi
	e2e_listed_check "記録あり $scene で一覧に PR" title
	[[ ! -e $e2e_record ]] || fail "記録あり $scene で一覧に PR: 記録が消えていない"
	[[ ! -s $e2e/sleeps ]] || fail "記録あり $scene で一覧に PR: 待った"
	expect "記録あり $scene で一覧に PR: API の呼び出し" "$(<"$e2e/curl-count")" "$([[ $scene == token ]] && echo 0 || echo 1)"
done
# 一覧に PR があっても、pr_url を書けないときは、今と同じ警告で 1 で終わる。記録は変えず、PR を見つけられないという案内は出さない。
for scene in no-record record; do
	e2e_reset
	e2e_list_pr "$e2e_url" title
	touch "$e2e/fail-pr_url"
	if [[ $scene == record ]]; then mkdir -p "$(dirname "$e2e_record")" && printf 'repository: example/template\n' >"$e2e_record"; fi
	e2e_run 1 TASK-7 "$e2e_url"
	[[ ! -s $e2e/out ]] || fail "一覧に PR で pr_url を書けない($scene): 標準出力が空でない"
	grep -qF "タスク TASK-7 に PR $e2e_url を紐付けられませんでした（metadata を書けない）" "$e2e/err" || { cat "$e2e/err" >&2; fail "一覧に PR で pr_url を書けない($scene): 警告がない"; }
	if grep -qF 'サーバーは、' "$e2e/err"; then fail "一覧に PR で pr_url を書けない($scene): PR を見つけられないという案内を出した"; fi
	expect "一覧に PR で pr_url を書けない($scene): pr_url" "$(e2e_field pr_url)" なし
	expect "一覧に PR で pr_url を書けない($scene): 連携なしの欄" "$(e2e_field pr_link_no_integration)" なし
	if [[ $scene == record ]]; then
		expect "一覧に PR で pr_url を書けない($scene): 記録" "$(cat "$e2e_record")" 'repository: example/template'
	else
		e2e_no_record
	fi
done
# 一覧を読めないか、一覧に別の PR だけがあるときは、読み直す前の失敗のとおりに動く。
for scene in unreadable other-pr empty; do
	e2e_reset
	case $scene in
	unreadable) touch "$e2e/fail-pulls" ;;
	other-pr) e2e_list_pr https://github.com/example/template/pull/34 title ;;
	esac
	e2e_run 0 TASK-7 "$e2e_url"
	expect "記録なし 404、一覧: $scene: 1 行目" "$(sed -n 1p "$e2e/out")" "連携なしにしました: TASK-7 $e2e_url"
	[[ ! -s $e2e/err ]] || { cat "$e2e/err" >&2; fail "記録なし 404、一覧: $scene: 標準エラーが空でない"; }
	[[ -f $e2e_record ]] || fail "記録なし 404、一覧: $scene: 記録ができていない"
	expect "記録なし 404、一覧: $scene: 一覧は 1 回だけ読む" "$(e2e_pulls_calls)" 1
	e2e_reset
	mkdir -p "$(dirname "$e2e_record")" && printf 'repository: example/template\n' >"$e2e_record"
	case $scene in
	unreadable) touch "$e2e/fail-pulls" ;;
	other-pr) e2e_list_pr https://github.com/example/template/pull/34 title ;;
	esac
	e2e_run 0 TASK-7 "$e2e_url"
	expect "記録あり 404、一覧: $scene: 出力" "$(cat "$e2e/out")" "紐付けていません（連携なし）: TASK-7 $e2e_url"
	[[ -f $e2e_record ]] || fail "記録あり 404、一覧: $scene: 記録が消えた"
	for key in pr_url pr_link_pending pr_link_no_integration; do expect "記録あり 404、一覧: $scene: $key" "$(e2e_field "$key")" "$e2e_url"; done
done
# 一覧に PR がなく、404 以外で失敗したときは、今と同じ警告で 1 で終わり、記録を書かない。
e2e_reset
printf '[500]\n' >"$e2e/statuses.json"
e2e_run 1 TASK-7 "$e2e_url"
e2e_warn_not_found
e2e_no_record
expect '一覧に PR がなく 500: 一覧は 1 回だけ読む' "$(e2e_pulls_calls)" 1
# link_source がないか、英小文字と _ 以外を含むときは、紐付け方に不明を出す。
for source in '' 'Title' 'a-b' 'title2' 'ti tle'; do
	e2e_reset
	e2e_list_pr "$e2e_url" "$source"
	e2e_run 0 TASK-7 "$e2e_url"
	e2e_listed_check "link_source [$source]" 不明
done
e2e_reset
e2e_list_pr "$e2e_url"
e2e_run 0 TASK-7 "$e2e_url"
e2e_listed_check 'link_source がない' 不明
e2e_reset
jq -n --arg url "$e2e_url" '{pull_requests: [{html_url: $url, link_source: null}]}' >"$e2e/pulls.json"
e2e_run 0 TASK-7 "$e2e_url"
e2e_listed_check 'link_source が null' 不明
e2e_reset
e2e_list_pr "$e2e_url" auto_title
e2e_run 0 TASK-7 "$e2e_url"
e2e_listed_check 'link_source に _ を含む' auto_title
# 一覧を読まない: 紐付けが 200、作業先が PR のリポジトリと違う、200 のあとに pr_url を書けない、pr_url がすでにある。
e2e_reset
printf '[200]\n' >"$e2e/statuses.json"
e2e_list_pr "$e2e_url" title
e2e_run 0 TASK-7 "$e2e_url"
expect '紐付けが 200: 出力' "$(cat "$e2e/out")" "紐付けました: TASK-7 $e2e_url"
expect '紐付けが 200: 一覧を読まない' "$(e2e_pulls_calls)" 0
e2e_reset
jq '.metadata.repository = "other/service"' "$e2e/issue.json" >"$e2e/next.json" && mv "$e2e/next.json" "$e2e/issue.json"
e2e_list_pr "$e2e_url" title
e2e_run 1 TASK-7 "$e2e_url"
[[ ! -s $e2e/out ]] || fail '作業先が違う: 標準出力が空でない'
expect '作業先が違う: 一覧を読まない' "$(e2e_pulls_calls)" 0
e2e_reset
printf '[200]\n' >"$e2e/statuses.json"
e2e_list_pr "$e2e_url" title
touch "$e2e/fail-pr_url"
e2e_run 1 TASK-7 "$e2e_url"
[[ ! -s $e2e/out ]] || fail '200 のあとに pr_url を書けない: 標準出力が空でない'
expect '200 のあとに pr_url を書けない: 一覧を読まない' "$(e2e_pulls_calls)" 0
e2e_reset
mkdir -p "$(dirname "$e2e_record")" && printf 'repository: example/template\n' >"$e2e_record"
printf '[200]\n' >"$e2e/statuses.json"
e2e_list_pr "$e2e_url" title
touch "$e2e/fail-pr_url"
e2e_run 1 TASK-7 "$e2e_url"
expect '記録ありで 200 のあとに pr_url を書けない: 一覧を読まない' "$(e2e_pulls_calls)" 0
e2e_reset
jq --arg url "$e2e_url" '.metadata.pr_url = $url' "$e2e/issue.json" >"$e2e/next.json" && mv "$e2e/next.json" "$e2e/issue.json"
e2e_list_pr "$e2e_url" title
e2e_run 0 TASK-7 "$e2e_url"
expect 'pr_url がある: 一覧を読まない' "$(e2e_pulls_calls)" 0

echo 'PASS pr-link-no-integration: 記録のパスの検査・作成・消去・同時の作成・PR_LINK_ALL_404・呼ぶ人間・欄の約束・squad-pr-link の記録の動作と一覧の読み直し'
