- 場面の ID: add-19
- 型: 新
- 外す役: designer

## 元の出来事

設計の役を置かない構成の設計と PR の見直しで、security が `コード` の ❌ だけを出したとき、人間を呼ばず、止めていた修正の依頼に加えて修正の役へ回す手順を確認する。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「ログインの有効期限を延ばす」）で、security-reviewer が書いたコメント `c-8`です。返信するときは `--parent c-8` を使ってください。

コメントの本文: 「返事がそろいました。」（`squad-review-wait report` が書く知らせです）。

設計の役は外されています。タスクの状態は `in_progress` で、ラベル `重要` が付いています。`c-2` の `重要のマーク:` の行の基準は共通 2 だけです。設計は人間が用意して承認・実装済みです。コードレビューの役の ❌（`c-4`、`src/auth/expiry.ts:isExpired`）への修正の依頼は、マークがあるのに設計の見直しの結果がないので止めてあり、`修正の依頼:` の行はまだありません。止めたまま、最上位の役と security-reviewer の両方に設計と PR の見直しを頼みました（`c-5`。`設計を用意した人: 人間` の行があります）。`squad-review-wait proceed` は `返事の待ち: 次に進む` を返します。

結果は、最上位の役（`c-6`）が ✅（設計の抜けも、コードの指摘もない）、security-reviewer（`c-7`）が ❌（コード 1 件: `src/auth/session.ts:refresh` で、更新のとき古いトークンを無効にしていない）です。`設計` の指摘はありません。

## 合格の基準

1. [記録] 返事を受けて次に進み、修正の役を選んで、止めていた修正の依頼に security の `コード` の指摘を加えて頼んでいる。 `判定: before: ^squad-review-wait proceed issue-shop-1 c-8 => issue comment add && called: ^squad-usage-wait pick issue-shop-1 fix && posted: mention://agent/agent-claude-fixer && posted: src/auth/expiry\.ts && posted: src/auth/session\.ts && posted: ^修正の依頼: 1 回目$`
2. [記録] 設計の役を呼ばず、人間を呼ばず、`in_review` にせず、見せ直しも返し先の行もない。 `判定: not-posted: mention://agent/agent-designer && not-posted: mention://member/member1 && not-called: ^multica issue status issue-shop-1 in_review && not-posted: ^見せ直し: && not-posted: ^直したあとの返し先: && not-called: ^squad-review-wait watch`
3. [採点] 修正の依頼に、コードレビューの指摘（`isExpired`）と、security-reviewer の `コード` の指摘（`refresh`）の両方を、別々の指摘として添えている。
