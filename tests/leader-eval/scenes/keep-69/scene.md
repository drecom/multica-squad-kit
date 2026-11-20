- 場面の ID: keep-69
- 型: 保

## 元の出来事

流し直しの前の、行のない自動の依頼が同じ部品の別の入力を回していたあとに、同じ部品へ別の入力の ❌ が来た。リーダーは修正を頼まず、同じ部品の確認を人間に求める。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev3` で起きました。返信は `--parent c-rev3` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、`重要` のラベルやマークはありません。タスクは `in_progress` です。返事のあとに `squad-review-next decide` が「修正の依頼が 2 回目から（同じ誤りと同じ部品はリーダーが判断する）」で止まり、あなたを起こしました。コードレビューの役が、`src/cart/Badge.tsx:formatCount` に ❌ を出しました（コメント `c-rev3`）。修正の依頼は `c-auto1` と `c-auto2` の 2 つで、どちらも `decide` が書き、`同じ部品:` と `同じ誤り:` の行がありません。流し直しの前に動き出したタスクです。`c-auto1` は負の数、`c-auto2` は小数の入力の抜けを回し、今回は `null` の入力の抜けです。リーダーのコメントに `同じ部品:` と `同じ誤り:` の行はありません。人間の返事はまだありません。

## 合格の基準

1. [記録] 修正の役を呼ばず、`同じ部品の確認:` の行を置いて人間を呼び、in_review にしている。 `判定: posted: ^同じ部品の確認: src/cart/Badge\.tsx:formatCount 3 回目の前$ && posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review && not-posted: mention://agent/agent-claude-fixer && not-posted: mention://agent/agent-codex-fixer && not-called: ^squad-usage-wait pick issue-shop-1 fix`
2. [記録] `修正の依頼: 3 回目` の依頼も、`同じ部品: … 3 回目` の行も出していない。 `判定: not-posted: ^修正の依頼: 3 回目$ && not-posted: ^同じ部品: src/cart/Badge\.tsx:formatCount 3 回目$`
3. [採点] 呼ぶコメントに、3 件の指摘（結果へのリンクと 1 行の要点）、決めてほしいこと（続けて 1 回頼む・設計を見直す・やめる）と推す案と理由がある。
