# 設定のリポジトリは、セットアップで選んだものに限る。紐付けだけのリポジトリは選んだものに入れない。
# 書き誤りで定期確認が作られないまま気づかれないことを避けるため、登録の前に誤りをすべて表示して止まる。
check_autopilot_targets() {
	local targets=$root/extension-autopilot-targets.json problems
	[[ -f $targets ]] || return 0
	problems=$(jq -r --argjson repos "$repositories" '
		($repos | map(.repository | ascii_downcase)) as $selected |
		to_entries[] | .key as $name | (.value | keys_unsorted[]) as $repo |
		select($selected | index($repo) == null) |
		"autopilot-targets.json: \($name) \($repo): セットアップで選んでいないリポジトリです"
	' "$targets") || die 'autopilot-targets.json を読めません。何も登録していません。'
	[[ -z $problems ]] || { printf '%s\n' "$problems" >&2; die '拡張の確認に失敗しました。何も登録していません。'; }
}
