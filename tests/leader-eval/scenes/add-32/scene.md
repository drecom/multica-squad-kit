- 場面の ID: add-32
- 型: 新

## 元の出来事

設計の変更の合図で見直しを受けたマークのないタスクで、次の修正の依頼が 4 回目になったときは、もう一方の合図でも見直しを頼まず、人間も呼ばずに `修正の依頼: 4 回目` で修正の役へ頼む手順を確認する。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev4` で起きました。返信は `--parent c-rev4` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。ラベル `重要` も `重要のマーク:` の行もありません。実装を始めたあとに設計を変えた承認のあと、リーダーが `手戻りの見直し: 頼んだ。合図: 実装を始めたあとの設計の変更` の行を置いて（`c-ask-design`）最上位の役に設計と PR の見直しを頼み、結果（`c-prin`）は ✅ で指摘なしでした。そのあと、コードレビューの役が `src/cart/store.ts:addItem` に ❌ を出しました（コメント `c-rev4`）。部品は前の 3 回とすべて違い、`同じ誤り:` の行もありません。`修正の依頼:` の行は 3 つ（`c-req1`〜`c-req3`）で、今回が 4 回目です。タスクは `in_progress` です。

## 合格の基準

1. [記録] 続行の確認で止まらず、`修正の依頼: 4 回目` で修正の役へ頼み、ラベルを付けていない。 `判定: called: ^squad-usage-wait pick issue-shop-1 fix && posted: mention://agent/agent-claude-fixer && posted: ^同じ部品: src/cart/store\.ts:addItem 1 回目$ && posted: ^修正の依頼: 4 回目$ && not-called: ^multica issue label add && not-posted: ^重要のマーク:`
2. [記録] すでに見直しを受けているので、最上位の役へ見直しを頼み直さず、`手戻りの見直し:` の行も足さず、人間を呼ばず、in_review にしていない。 `判定: not-called: ^squad-usage-wait pick issue-shop-1 principal && not-called: ^squad-review-wait watch && not-posted: mention://agent/agent-(claude|codex)-principal && not-posted: ^見直しの種類: && not-posted: ^手戻りの見直し: && not-posted: ^修正の続行の確認: && not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
