# 本文の読み方の表（tests/review-body-table.tsv）を、1 行ずつコールバックへ渡す。source して使う。単独では実行しない。
# bash 3.2 でも動くよう、連想配列と mapfile は使わない。コールバックが標準入力を読んでも表を壊さないよう、表は fd 3 から読む。
# body_table <種類の行> <回の ID> <コールバック> [representative]
#   4 つ目に representative を渡すと、4 列目が `代表` の行だけを流す。3 つのコマンドのテストは、代表の行だけを流して時間を絞る。渡さなければ全行を流す。
#   コールバックは <期待> <説明> <本文の JSON 文字列> <行の番号または -> を受ける。期待は control、notcontrol、unreadable:<理由>。
#   本文は {K}（種類の行）、{R}（回の ID）、{B}（種類の行と前の回: の 2 行）を置き換え済み。NUL を含むことがあるので、JSON のまま扱う。
body_table_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review-body-table.tsv"
body_table() {
	local kind=$1 round=$2 callback=$3 only=${4-} expect label json tail count=0
	# read はタブが連続すると空欄を飛ばす。4・5 列目はまとめて読み、空の代表欄に対応する。
	while IFS=$'\t' read -r -u 3 expect label json tail; do
		[[ -n $expect && $expect != '#'* ]] || continue
		[[ $only != representative || $tail == 代表$'\t'* ]] || continue
		json=$(jq -nc --argjson text "$json" --arg kind "$kind" --arg round "$round" \
			'$text | gsub("\\{B\\}"; "{K}\n前の回: {R}") | gsub("\\{K\\}"; $kind) | gsub("\\{R\\}"; $round)')
		"$callback" "$expect" "$label" "$json" "${tail##*$'\t'}"
		count=$((count + 1))
	done 3<"$body_table_file"
	body_table_count=$count
}
