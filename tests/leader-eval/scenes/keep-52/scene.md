- 場面の ID: keep-52
- 型: 保

## 元の出来事

人間が付けたマークのタスクで、設計が認証に触れるとき、リーダーは設計を読んで共通 2 に当たると判断し、最上位の役と security-reviewer の両方に頼んだ。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「ログインにパスワードの再設定を足す」）に設計の役が書いたコメント `comment-3` です。返信するときは `--parent comment-3` を使ってください。

コメントの本文: 設計の draft PR を作ったという引き継ぎです。PR は紐付いています。

タスクの状態は `in_progress` で、人間が付けたラベル `重要` があります。`comment-2` の `重要のマーク:` の行は `人間が付けたマークを確認した。` だけで、基準はありません。設計は、再設定のリンクのトークンの発行・検証・期限を扱います。`共通 2 の判断:` の行は、まだタスクのどのコメントにもありません。

## 合格の基準

1. [記録] 使用率から最上位の役を選んでいる。 `判定: called: ^squad-usage-wait pick issue-shop-1 principal`
2. [記録] 最上位の役と security-reviewer の返事の待ちの見張りを、依頼の前に入れている。 `判定: before: ^squad-review-wait watch issue-shop-1 \S+ (agent-claude-principal agent-security-reviewer|agent-security-reviewer agent-claude-principal)$ => issue comment add`
3. [記録] 依頼に、`共通 2 の判断: 当たる`、見直しの種類、2 つの役を並べた返事を待つ役、確認するコミットの行がある。 `判定: posted: ^共通 2 の判断: 当たる。理由: \S && posted: ^見直しの種類: 設計の見直し && posted: ^返事を待つ役: (?=.*mention://agent/agent-claude-principal)(?=.*mention://agent/agent-security-reviewer) && posted: ^確認するコミット: [0-9a-f]{40}`
4. [記録] 返事の前に、人間を呼ばず、タスクを `in_review` にしていない。 `判定: not-posted: mention://member/member1 && not-called: ^multica issue status issue-shop-1 in_review`
