- 場面の ID: keep-47
- 型: 保

## 元の出来事

人間がラベルを外したタスクは、PR に最上位の役の設計の見直しの結果があれば、4 回目の前に続行の確認でも見直しでも止まらず、マークを付け直さない。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev4` で起きました。返信は `--parent c-rev4` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、人間がラベル `重要` を外しました。`c-mark` に `重要のマーク:` の行はありますが、今のラベルはありません。PR には、最上位の役の設計と PR の見直しの結果（`c-prin0`）が ✅ で残っています。タスクは `in_progress` です。コードレビューの役が、`src/cart/store.ts:addItem` に ❌ を出しました（コメント `c-rev4`）。部品は前の 3 回とすべて違い、`同じ誤り:` の行もありません。`修正の依頼:` の行は 3 つで、今回が 4 回目です。

## 合格の基準

1. [記録] 続行の確認で止まらず、`手戻りの見直し: 頼まない` の行を置き、`修正の依頼: 4 回目` で修正の役へ頼んでいる。 `判定: called: ^squad-usage-wait pick issue-shop-1 fix && posted: mention://agent/agent-claude-fixer && posted: ^同じ部品: src/cart/store\.ts:addItem 1 回目$ && posted: ^修正の依頼: 4 回目$ && posted: ^手戻りの見直し: 頼まない。合図: 修正の依頼が 4 回目`
2. [記録] マークを付け直さず、最上位の役も人間も呼ばず、in_review にしていない。 `判定: not-called: ^multica issue label add && not-called: ^squad-usage-wait pick issue-shop-1 principal && not-posted: ^修正の続行の確認: && not-posted: ^重要のマーク: && not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
