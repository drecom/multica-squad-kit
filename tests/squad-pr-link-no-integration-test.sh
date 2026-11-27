#!/usr/bin/env bash
# 連携なしの記録の共通の部品を、単体で確認する。
# 記録のパスの検査・作成・消去、pr_link_pull_request の PR_LINK_ALL_404、呼ぶ人間を決める関数、metadata の欄の約束を見る。
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
[[ -f $PR_LINK_RECORD_TMP && $PR_LINK_RECORD -ef $PR_LINK_RECORD_TMP ]] || fail '一時ファイルは記録と同じファイル'
pr_link_record_exists "$project" "$pr_url" || fail '作ったあとは exists が 0'
pr_link_record_finish
expect 'finish で一時ファイルだけが消える' "$(ls -A "$PR_LINK_RECORD_DIR")" repo.name
[[ -f $record ]] || fail 'finish は記録を消さない'

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

# --- 消去: 自分の記録だけを消す ---
rm -f "$record"
pr_link_record_create "$project" "$pr_url" TASK-1 || fail '自分の記録を作る'
pr_link_record_discard_own
[[ ! -e $record ]] || fail '自分の記録を消す'
expect '自分の記録を消したあとに一時ファイルが残らない' "$(ls -A "$PR_LINK_RECORD_DIR")" ''
pr_link_record_create "$project" "$pr_url" TASK-1 || fail '記録を作り直す'
mine=$PR_LINK_RECORD_TMP
rm -f "$record"
printf 'other\n' >"$record"
pr_link_record_discard_own
expect '別の実行の記録は消さない' "$(cat "$record")" other
[[ ! -e $mine ]] || fail '別の記録を残しても自分の一時ファイルは消す'
rc=0
pr_link_record_create "$project" "$pr_url" TASK-2 || rc=$?
expect '作れなかった実行の discard は何も消さない' "$rc" 2
pr_link_record_discard_own
expect '作れなかった実行の discard のあとも記録が残る' "$(cat "$record")" other

# --- 消去: remove は記録があるときだけ消す ---
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

echo 'PASS pr-link-no-integration: 記録のパスの検査・作成・消去・同時の作成・PR_LINK_ALL_404・呼ぶ人間・欄の約束'
