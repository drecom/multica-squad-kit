- 場面の ID: keep-62
- 型: 保

## 元の出来事

マークのあるタスクで、続けると返したあとの 6 回目の前にも止まらない。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev6` で起きました。返信は `--parent c-rev6` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、ラベル `重要` が付いていて、`c-mark` に `重要のマーク:` の行があります。タスクは `in_progress` です。`c-conf4` の続行の確認に人間が続けると返し（`c-ok4`）、5 回目の依頼（`c-req5`）と修正（`c-fix5`）まで済んでいます。コードレビューの役が、`src/cart/Badge.css:size` に ❌ を出しました（コメント `c-rev6`）。部品は前の 5 回とすべて違い、`同じ誤り:` の行はありません。修正の依頼は今回が 6 回目です。

## 合格の基準

1. [記録] 止まらずに、`修正の依頼: 6 回目` で修正の役へ頼んでいる。 `判定: called: ^squad-usage-wait pick issue-shop-1 fix && posted: mention://agent/agent-claude-fixer && posted: ^同じ部品: src/cart/Badge\.css:size 1 回目$ && posted: ^修正の依頼: 6 回目$`
2. [記録] 人間を呼ばず、続行の確認の行も置かず、in_review にしていない。 `判定: not-posted: mention://member/member1 && not-posted: ^修正の続行の確認: && not-called: ^multica issue status .* in_review`
3. [採点] 依頼の文が、`c-rev6` の指摘（狭い幅ではみ出す）の修正を頼んでいる。
