- 場面の ID: keep-51
- 型: 保

## 元の出来事

security-reviewer を置かないスクワッドで、共通 2 のタスクの設計が返ったとき、リーダーは最上位の役だけに、入力と信頼の表の確認を添えて頼んだ。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「ログインの有効期限を延ばす」）に設計の役が書いたコメント `comment-3` です。返信するときは `--parent comment-3` を使ってください。

コメントの本文: 設計の draft PR を作ったという引き継ぎです。PR は紐付いています。

タスクの状態は `in_progress` で、ラベル `重要` が付いています。`comment-2` の `重要のマーク:` の行の基準は共通 2 です。このスクワッドに security-reviewer はいません。

## 合格の基準

1. [記録] 使用率から最上位の役を選び、最上位の役だけの返事の待ちの見張りを、見直しの依頼の前に入れている。 `判定: called: ^squad-usage-wait pick issue-shop-1 principal && before: ^squad-review-wait watch issue-shop-1 \S+ agent-claude-principal$ => issue comment add`
2. [記録] 依頼に、見直しの種類、返事を待つ役、確認するコミット、入力と信頼の表の確認の行がある。 `判定: posted: ^見直しの種類: 設計の見直し && posted: ^返事を待つ役: .*mention://agent/agent-claude-principal && posted: ^確認するコミット: [0-9a-f]{40} && posted: ^入力と信頼の表の確認: 頼む$`
3. [記録] security-reviewer を呼んでいない。ほかの役に代わりの実行も頼んでいない。 `判定: not-called: ^squad-review-wait watch .*agent-security-reviewer && not-posted: mention://agent/agent-security-reviewer && not-posted: mention://agent/agent-(code|ux|performance)-reviewer`
4. [記録] 返事の前に、人間を呼ばず、タスクを `in_review` にしていない。 `判定: not-posted: mention://member/member1 && not-called: ^multica issue status issue-shop-1 in_review`
