# squad-review-next-decide-merge-note*-test.sh が読み込む共通の準備（マージの依頼に書く注意の見本と補助）。単独では実行しない。
# review-next-decide-common.sh を読み込んだあとで読み込む。
conf_line="コンフリクト: MERGEABLE head: $sha"
final_ok() { # 最終レビューまで済んだ状態にする。回は final-1
	set_merge_roster
	ok_round
	final_round final-1 "$sha" round-1
	result final-1 claude-principal ✅ "$sha" なし
}

plain_lines=('✅ demo-code-reviewer-test: 結果' '✅ demo-qa-test: 結果')
# 読む深さは、注意の状態で決まる。注意が「なし」ならコメントだけ、読めないなら注意を読めない、それ以外は注意あり。
depth_of() { # 注意の行（最初の行）
	local state=注意あり
	case $1 in
	*': なし') state=注意なし ;;
	*': 読めない（'*) state=注意を読めない ;;
	esac
	if [[ $state == 注意なし ]]; then
		printf '読む深さ: このコメントだけ（重要でない。注意なし、残した指摘 0 件、前からある不具合 0 件）'
	else
		printf '読む深さ: このコメントと PR の注意（重要でない。%s、残した指摘 0 件、前からある不具合 0 件）' "$state"
	fi
}
note_case() { # PR の本文 期待する行（複数の行は改行で続ける）
	reset
	set_roster orchestrator code-reviewer qa
	ok_round
	set_pr_body "$1"
	merge_note=$2
	merge_depth=$(depth_of "${2%%$'\n'*}")
	run round-1
	expect_merge_posted "$(merge_body round-1 "$sha" "$conf_line" "${plain_lines[@]}")"
	expect_calls body-calls 'pr view 7 --repo demo/project --json body'
}
N=マージの前に人間がすること
