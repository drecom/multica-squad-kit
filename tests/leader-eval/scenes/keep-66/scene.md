- 場面の ID: keep-66
- 型: 保

## 元の出来事

自動の依頼が頼み直しの回を指し、元の回で指摘された部品へ別の入力の ❌ が来たとき、リーダーは種類単位で修正を頼む。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev3` で起きました。返信は `--parent c-rev3` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、`重要` のラベルやマークはありません。タスクは `in_progress` です。返事のあとに `squad-review-next decide` が「修正の依頼が 2 回目から（同じ誤りと同じ部品はリーダーが判断する）」で止まり、あなたを起こしました。コードレビューの役が、`src/cart/Badge.tsx:formatCount` に ❌ を出しました（コメント `c-rev3`）。最初の回（`c-round1`）では、コードレビューが ❌ を出し、QA は確認したコミットが合わず、QA だけを頼み直しました（`c-round2`）。その返事（`c-qa2`）が ✅ でそろったあとに、`decide` が修正の依頼 `c-auto1` を書きました。`c-auto1` の `前の回:` は `c-round2` を指し、`同じ部品:` の行がありません。`c-auto1` で直した入力（負の数）とは別の入力（小数）の抜けです。`同じ誤り:` の行も `同じ部品:` の行も、リーダーのコメントにはまだありません。

## 合格の基準

1. [記録] 同じ部品の 2 回目と種類単位の範囲を添えて頼んでいる。 `判定: called: ^squad-usage-wait pick issue-shop-1 fix && posted: mention://agent/agent-claude-fixer && posted: ^同じ部品: src/cart/Badge\.tsx:formatCount 2 回目$ && posted: ^頼む範囲: 種類単位（src/cart/Badge\.tsx:formatCount）$ && posted: ^修正の依頼: 2 回目$`
2. [記録] 人間を呼ばず、同じ誤りの行も置かず、in_review にしていない。 `判定: not-posted: ^同じ誤り: && not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
3. [採点] 頼み直しの回（`c-round2`）の返事が ✅ だけでも、`c-auto1` が直した指摘を、元の回（`c-round1`）のコードレビューの ❌ から読んでいる。依頼の文が、種類単位で表を作ることと、指摘された 2 件の入力（負の数と小数）を表に含めることを頼んでいる。
