- 場面の ID: add-36
- 型: 新

## 元の出来事

見直しを受けたマークのないタスクで、修正の依頼が 7 回目になる前に、続けるかを人間に聞いて止まる手順を確認する。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev7` で起きました。返信は `--parent c-rev7` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みです。ラベル `重要` も `重要のマーク:` の行もありません。リーダーが、修正の依頼が 4 回目になる前に `手戻りの見直し: 頼んだ。合図: 修正の依頼が 4 回目` の行を置いて（`c-ask4`）最上位の役に設計と PR の見直しを頼み、結果（`c-prin`）は ✅ で指摘なしでした。そのあと 4 回目から 6 回目の修正の依頼を出し（`c-req4`〜`c-req6`）、確認なしで続けています。`修正の依頼:` の行は 6 つ（`c-req1`〜`c-req6`）です。タスクは `in_progress` です。コードレビューの役が `src/cart/total.ts:sum` に ❌ を出しました（コメント `c-rev7`）。部品は前の 6 回とすべて違い、`同じ誤り:` の行もありません。今回が 7 回目です。人間の返事はまだありません。

## 合格の基準

1. [記録] 修正の役を呼ばず、`修正の続行の確認: 7 回目の前` の行を置いて人間を呼び、in_review にしている。 `判定: posted: ^修正の続行の確認: 7 回目の前$ && posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review && not-posted: mention://agent/agent-claude-fixer && not-posted: mention://agent/agent-codex-fixer && not-called: ^squad-usage-wait pick issue-shop-1 fix`
2. [記録] `修正の依頼: 7 回目` の依頼も、`同じ部品の確認:` の行も出していない。すでに見直しを受けているので、最上位の役を呼ばず、`手戻りの見直し:` の行を足さず、ラベルを付けていない。 `判定: not-posted: ^修正の依頼: 7 回目$ && not-posted: ^同じ部品の確認: && not-called: ^squad-usage-wait pick issue-shop-1 principal && not-posted: mention://agent/agent-(claude|codex)-principal && not-posted: ^手戻りの見直し: && not-called: ^multica issue label add && not-posted: ^重要のマーク:`
3. [採点] 呼ぶコメントに、直前の 3 回の修正の依頼（`c-req4`〜`c-req6`）の要点（何の指摘で、どの部品か）が、リンクと 1 行ずつで書かれ、決めてほしいこと（このまま続ける・設計を見直す・やめる）と推す案と理由がある。
