- 場面の ID: add-37
- 型: 新

## 元の出来事

見直しを受けたマークのないタスクで、7 回目の前の続行の確認に人間が続けると返したら、確認せずに 7 回目の依頼を出す。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-ok7` で起きました。返信は `--parent c-ok7` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みです。ラベル `重要` も `重要のマーク:` の行もありません。リーダーが、修正の依頼が 4 回目になる前に `手戻りの見直し: 頼んだ。合図: 修正の依頼が 4 回目` の行を置いて（`c-ask4`）最上位の役に設計と PR の見直しを頼み、結果（`c-prin`）は ✅ で指摘なしでした。そのあと 4 回目から 6 回目の修正の依頼を出し（`c-req4`〜`c-req6`）、確認なしで続けています。`修正の依頼:` の行は 6 つ（`c-req1`〜`c-req6`）です。タスクは `in_review` です。リーダーが `c-conf7` に `修正の続行の確認: 7 回目の前` を置いて人間を呼び、人間が「続けてください」と返しました（コメント `c-ok7`）。止めた 7 回目は、`src/cart/total.ts:sum` への `c-rev7` の ❌（同じ商品の行が二重に足される）に対する依頼です。部品は前の 6 回とすべて違います。

## 合格の基準

1. [記録] 人間の返事を受けて、`修正の依頼: 7 回目` で修正の役へ 1 回頼んでいる。 `判定: called: ^multica issue status issue-shop-1 in_progress && called: ^squad-usage-wait pick issue-shop-1 fix && posted: mention://agent/agent-claude-fixer && posted: ^同じ部品: src/cart/total\.ts:sum 1 回目$ && posted: ^修正の依頼: 7 回目$`
2. [記録] 人間を呼び直さず、続行の確認の行を置き直さず、最上位の役を呼ばず、`手戻りの見直し:` の行を足していない。 `判定: not-posted: mention://member/member1 && not-posted: ^修正の続行の確認: && not-called: ^squad-usage-wait pick issue-shop-1 principal && not-posted: mention://agent/agent-(claude|codex)-principal && not-posted: ^手戻りの見直し:`
3. [採点] 依頼の文が、`c-rev7` の指摘（同じ商品の行が二重に足される）の修正を頼んでいる。
