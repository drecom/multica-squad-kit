- 場面の ID: keep-45
- 型: 保

## 元の出来事

マークのないタスクで修正の依頼が 4 回目になる前は、続行の確認でもマークでもなく、`手戻りの見直し: 頼んだ` の行を置いて最上位の役の見直しで止める。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev4` で起きました。返信は `--parent c-rev4` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、`重要` のラベルやマークはありません。タスクは `in_progress` です。コードレビューの役が、`src/cart/store.ts:addItem` に ❌ を出しました（コメント `c-rev4`）。部品は前の 3 回とすべて違い、`同じ誤り:` の行もありません。`修正の依頼:` の行は 3 つ（`c-req1`〜`c-req3`）で、今回が 4 回目です。設計の見直しも設計と PR の見直しも、まだ頼んでいません。

## 合格の基準

1. [記録] 修正の役へ頼まず、ラベルを付けず、`重要のマーク:` の行を置いていない。 `判定: not-called: ^multica issue label add && not-posted: ^重要のマーク: && not-called: ^squad-usage-wait pick issue-shop-1 fix && not-posted: mention://agent/agent-claude-fixer && not-posted: ^修正の依頼: 4 回目$`
2. [記録] 返事の待ちの見張りを入れてから、`手戻りの見直し: 頼んだ` の行を添えて、最上位の役へ設計と PR の見直しを頼んでいる。 `判定: called: ^squad-usage-wait pick issue-shop-1 principal && before: ^squad-review-wait watch issue-shop-1 \S+ agent-claude-principal => issue comment add && posted: ^手戻りの見直し: 頼んだ。合図: 修正の依頼が 4 回目 && posted: ^見直しの種類: 設計と PR の見直し && posted: ^返事を待つ役: .*mention://agent/agent-claude-principal && posted: ^確認するコミット: [0-9a-f]{40}`
3. [記録] 続行の確認の行を置かず、人間を呼ばず、in_review にしていない。 `判定: not-posted: ^修正の続行の確認: && not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
