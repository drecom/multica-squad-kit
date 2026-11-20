- 場面の ID: keep-64
- 型: 保

## 元の出来事

自動の 1 回目のあとに違う部品へ ❌ が来たとき、リーダーはその部品を 1 回目として、指摘ごとに頼む。種類単位にはしない。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev2` で起きました。返信は `--parent c-rev2` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、`重要` のラベルやマークはありません。タスクは `in_progress` です。返事のあとに `squad-review-next decide` が「修正の依頼が 2 回目から（同じ誤りと同じ部品はリーダーが判断する）」で止まり、あなたを起こしました。コードレビューの役が、`src/cart/CartIcon.tsx:CartIcon` に ❌ を出しました（コメント `c-rev2`）。直前の修正の依頼 `c-auto1` は、`decide` が書いたもので、`src/cart/Badge.tsx:formatCount` を直す依頼で、`同じ部品:` の行がありません。その部品とは別の部品の抜けです。`同じ誤り:` の行も `同じ部品:` の行も、リーダーのコメントにはまだありません。

## 合格の基準

1. [記録] 修正の役へ、新しい部品の 1 回目として頼んでいる。 `判定: called: ^squad-usage-wait pick issue-shop-1 fix && posted: mention://agent/agent-claude-fixer && posted: ^同じ部品: src/cart/CartIcon\.tsx:CartIcon 1 回目$ && posted: ^修正の依頼: 2 回目$`
2. [記録] 種類単位の範囲も、同じ誤りの行も置かず、人間を呼ばず、in_review にしていない。 `判定: not-posted: ^頼む範囲: && not-posted: ^同じ誤り: && not-posted: ^同じ部品: src/cart/Badge\.tsx && not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
3. [採点] 依頼の文が、`c-rev2` の指摘（商品が 0 件でもバッジが出る）を直すことを頼み、前の部品の指摘を持ち込んでいない。
