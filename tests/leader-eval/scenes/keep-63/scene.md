- 場面の ID: keep-63
- 型: 保

## 元の出来事

自動の 1 回目のあとに同じ部品へ別の入力の ❌ が来たとき、リーダーは種類単位で修正を頼む。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev2` で起きました。返信は `--parent c-rev2` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、`重要` のラベルやマークはありません。タスクは `in_progress` です。返事のあとに `squad-review-next decide` が「修正の依頼が 2 回目から（同じ誤りと同じ部品はリーダーが判断する）」で止まり、あなたを起こしました。コードレビューの役が、`src/cart/Badge.tsx:formatCount` に ❌ を出しました（コメント `c-rev2`）。直前の修正の依頼 `c-auto1` は、`decide` が書いたもので、`同じ部品:` の行がありません。`c-auto1` で直した入力（負の数）とは別の入力（小数）の抜けです。`同じ誤り:` の行も `同じ部品:` の行も、リーダーのコメントにはまだありません。

## 合格の基準

1. [記録] 修正の役へ、同じ部品の 2 回目と種類単位の範囲を添えて頼んでいる。 `判定: called: ^squad-usage-wait pick issue-shop-1 fix && posted: mention://agent/agent-claude-fixer && posted: ^同じ部品: src/cart/Badge\.tsx:formatCount 2 回目$ && posted: ^頼む範囲: 種類単位（src/cart/Badge\.tsx:formatCount）$ && posted: ^修正の依頼: 2 回目$`
2. [記録] 同じ部品の 1 回目として数え直した行も、同じ誤りの行も置かず、人間を呼ばず、in_review にしていない。 `判定: not-posted: ^同じ部品: src/cart/Badge\.tsx:formatCount 1 回目$ && not-posted: ^同じ誤り: && not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
3. [採点] 依頼の文が、その部品が受ける入力の種類と規則を表にして扱いを決めること、表の行ごとにテストを置くこと、表の場所を結果に書くこと、指摘された 2 件の入力（負の数と小数）を表の行に含めることを頼んでいる。1 件ずつの入力の直しだけを頼んでいない。
