- 場面の ID: add-40
- 型: 新

## 元の出来事

過去に共通 4 でマークが付いたタスクで、修正の依頼が 7 回目になる前に、マークのあるタスクとして続けるかを人間に聞いて止まる手順を確認する。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev7` で起きました。返信は `--parent c-rev7` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みです。ラベル `重要` が付いたままで、`c-mark4` の `重要のマーク:` の行の基準は共通 4（修正の依頼が 4 回目になる）です。リーダーが `c-mark4` で最上位の役に設計と PR の見直しを頼み、結果（`c-prin`）は ✅ で指摘なしでした。4 回目の依頼は、そのマークが `c-req3` より後にあったので確認なしで出し（`c-req4`）、そのあと 6 回目まで出しました（`c-req5`、`c-req6`）。`修正の依頼:` の行は 6 つ（`c-req1`〜`c-req6`）で、`c-req6` より後に、リーダーの `重要のマーク:` の行も `手戻りの見直し:` の行もありません。タスクは `in_progress` です。コードレビューの役が `src/cart/total.ts:sum` に ❌ を出しました（コメント `c-rev7`）。部品は前の 6 回とすべて違い、`同じ誤り:` の行もありません。今回が 7 回目です。人間の返事はまだありません。

## 合格の基準

1. [記録] 修正の役を呼ばず、`修正の続行の確認: 7 回目の前` の行を置いて人間を呼び、in_review にしている。 `判定: posted: ^修正の続行の確認: 7 回目の前$ && posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review && not-posted: mention://agent/agent-claude-fixer && not-posted: mention://agent/agent-codex-fixer && not-called: ^squad-usage-wait pick issue-shop-1 fix`
2. [記録] ラベルを外さず、最上位の役を呼ばず、`手戻りの見直し:` の行も `修正の依頼: 7 回目` の依頼も出していない。 `判定: not-called: ^multica issue label (remove|rm|delete) && not-called: ^squad-usage-wait pick issue-shop-1 principal && not-posted: mention://agent/agent-(claude|codex)-principal && not-posted: ^手戻りの見直し: && not-posted: ^修正の依頼: 7 回目$`
3. [採点] 呼ぶコメントに、直前の 3 回の修正の依頼（`c-req4`〜`c-req6`）の要点が、リンクと 1 行ずつで書かれ、決めてほしいこと（このまま続ける・設計を見直す・やめる）と推す案と理由がある。
