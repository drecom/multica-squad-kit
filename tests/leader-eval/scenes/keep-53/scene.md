- 場面の ID: keep-53
- 型: 保

## 元の出来事

人間が付けたマークのタスクで、設計が画面の文言だけを直すとき、リーダーは設計を読んで共通 2 に当たらないと判断し、最上位の役だけに頼んだ。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「注文の画面の文言を直す」）に設計の役が書いたコメント `comment-3` です。返信するときは `--parent comment-3` を使ってください。

コメントの本文: 設計の draft PR を作ったという引き継ぎです。PR は紐付いています。

タスクの状態は `in_progress` で、人間が付けたラベル `重要` があります。`comment-2` の `重要のマーク:` の行は `人間が付けたマークを確認した。` だけで、基準はありません。設計は、ボタンの文言の変更だけを扱い、認証・権限・秘密の情報には触れません。`共通 2 の判断:` の行は、まだタスクのどのコメントにもありません。

## 合格の基準

1. [記録] 使用率から最上位の役を選び、最上位の役だけの返事の待ちの見張りを、依頼の前に入れている。 `判定: called: ^squad-usage-wait pick issue-shop-1 principal && before: ^squad-review-wait watch issue-shop-1 \S+ agent-claude-principal$ => issue comment add`
2. [記録] 依頼に、`共通 2 の判断: 当たらない`、見直しの種類、返事を待つ役、確認するコミットの行がある。 `判定: posted: ^共通 2 の判断: 当たらない。理由: \S && posted: ^見直しの種類: 設計の見直し && posted: ^返事を待つ役: .*mention://agent/agent-claude-principal && posted: ^確認するコミット: [0-9a-f]{40}`
3. [記録] security-reviewer を見張りにも依頼にも入れていない。表の確認の行もない。 `判定: not-called: ^squad-review-wait watch .*agent-security-reviewer && not-posted: mention://agent/agent-security-reviewer && not-posted: ^入力と信頼の表の確認:`
4. [記録] 返事の前に、人間を呼ばず、タスクを `in_review` にしていない。 `判定: not-posted: mention://member/member1 && not-called: ^multica issue status issue-shop-1 in_review`
