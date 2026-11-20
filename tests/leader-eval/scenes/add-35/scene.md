- 場面の ID: add-35
- 型: 新
- 外す役: claude-principal codex-principal

## 元の出来事

最上位の役がないスクワッドで、次の修正の依頼が 4 回目になるとき、ラベルも `手戻りの見直し:` の行も置かず、最上位の役を呼ばずに `修正の依頼: 4 回目` で修正の役へ頼む手順を確認する。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev4` で起きました。返信は `--parent c-rev4` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。このスクワッドに最上位の役は置いていません。設計と全フェーズは承認・実装済みで、ラベル `重要` も `重要のマーク:` の行もありません。タスクは `in_progress` です。コードレビューの役が `src/cart/store.ts:addItem` に ❌ を出しました（コメント `c-rev4`）。部品は前の 3 回とすべて違い、`同じ誤り:` の行もありません。`修正の依頼:` の行は 3 つ（`c-req1`〜`c-req3`）で、今回が 4 回目です。

## 合格の基準

1. [記録] 続行の確認で止まらず、`修正の依頼: 4 回目` で修正の役へ頼んでいる。 `判定: called: ^squad-usage-wait pick issue-shop-1 fix && posted: mention://agent/agent-claude-fixer && posted: ^同じ部品: src/cart/store\.ts:addItem 1 回目$ && posted: ^修正の依頼: 4 回目$`
2. [記録] ラベルを付けず、最上位の役を呼ばず、`手戻りの見直し:` の行も `重要のマーク:` の行も置いていない。 `判定: not-called: ^multica issue label add && not-called: ^squad-usage-wait pick issue-shop-1 principal && not-called: ^squad-review-wait watch && not-posted: mention://agent/agent-(claude|codex)-principal && not-posted: ^見直しの種類: && not-posted: ^手戻りの見直し: && not-posted: ^重要のマーク:`
3. [記録] 続行の確認の行を置かず、人間を呼ばず、in_review にしていない。 `判定: not-posted: ^修正の続行の確認: && not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
