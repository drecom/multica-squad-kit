- 場面の ID: add-33
- 型: 新

## 元の出来事

4 回目の合図で見直しを受けたマークのないタスクで、実装を始めたあとに変えた設計が承認されたとき、もう一方の合図でも見直しを頼まず、`手戻りの見直し:` の行を足さずに実装の役へ変えた設計の実装を頼む手順を確認する。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` に人間が書いたコメント `c-reapprove`（本文: 「変えた設計とフェーズを承認します。」）で起きました。返信は `--parent c-reapprove` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。ラベル `重要` も `重要のマーク:` の行もありません。修正の依頼が 4 回目になる前に、リーダーが `手戻りの見直し: 頼んだ。合図: 修正の依頼が 4 回目` の行を置いて（`c-ask4`）最上位の役に設計と PR の見直しを頼み、結果（`c-prin`）は設計の指摘でした。リーダーが設計の役へ設計の変更を頼み（`c-change`、`設計の変更: 実装を始めたあと` の行あり）、設計の役が直した設計を人間が承認しました。タスクの状態は `in_review` で、`修正の依頼:` の行は 3 つです。止めていた 4 回目の修正は、設計を直したので、直した設計の実装として頼みます。

## 合格の基準

1. [記録] 承認の返事を受けてタスクを `in_progress` に戻し、実装の役をメンションして変えた設計の実装を頼んでいる。ラベルを付けず、`手戻りの見直し:` の行を足していない。 `判定: called: ^multica issue status issue-shop-1 in_progress && posted: mention://agent/agent-(claude|codex)-implementer && not-called: ^multica issue label add && not-posted: ^重要のマーク: && not-posted: ^手戻りの見直し:`
2. [記録] すでに見直しを受けているので、最上位の役へ見直しを頼み直さず、修正の依頼の行も続行の確認の行も置かず、人間を呼んでいない。 `判定: not-called: ^squad-usage-wait pick issue-shop-1 principal && not-called: ^squad-review-wait watch && not-posted: mention://agent/agent-(claude|codex)-principal && not-posted: ^見直しの種類: && not-posted: ^修正の依頼: && not-posted: ^修正の続行の確認: && not-posted: mention://member/member1`
3. [採点] 実装の役への依頼に、設計の変更（`c-change`）と最上位の役の指摘（`c-prin`）へのリンクを添え、設計の文書を実装の役に直させていない。
