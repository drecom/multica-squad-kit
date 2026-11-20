- 場面の ID: add-18
- 型: 新
- 外す役: designer

## 元の出来事

設計の役を置かない構成の設計と PR の見直しで、security が `設計` の ❌ を出したとき、振り分けを止めたまま、人間に直しを頼んで返し先の行を置く手順を確認する。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「ログインの有効期限を延ばす」）で、security-reviewer が書いたコメント `c-8`です。返信するときは `--parent c-8` を使ってください。

コメントの本文: 「返事がそろいました。」（`squad-review-wait report` が書く知らせです）。

設計の役は外されています。タスクの状態は `in_progress` で、ラベル `重要` が付いています。`c-2` の `重要のマーク:` の行の基準は共通 2 だけです。設計は人間が用意して承認・実装済みです。コードレビューの役の ❌（`c-4`、`src/auth/expiry.ts:isExpired`）への修正の依頼は、マークがあるのに設計の見直しの結果がないので止めてあり、`修正の依頼:` の行はまだありません。止めたまま、最上位の役と security-reviewer の両方に設計と PR の見直しを頼みました（`c-5`。`設計を用意した人: 人間` の行があります）。`squad-review-wait proceed` は `返事の待ち: 次に進む` を返します。

結果は、最上位の役（`c-6`）が ✅（設計の抜けも、コードの指摘もない）、security-reviewer（`c-7`）が ❌（設計 1 件: 入力と信頼の表に、更新のトークンを受け取った人が本人かを確認する条件がない）です。`コード` の指摘はありません。

## 合格の基準

1. [記録] 返事を受けて次に進んでから、人間をメンションし、依頼に `直したあとの返し先: スクワッド` の行を置き、返事の書き方として「直した」と書く場合と直さずに進める場合の 2 つを示している。 `判定: before: ^squad-review-wait proceed issue-shop-1 c-8 => issue comment add && posted: mention://member/member1 && posted: ^直したあとの返し先: スクワッド$ && posted: 「直した」 && posted: 直さずに進める`
2. [記録] 振り分けを止めたまま、設計の役、実装の役、修正の役を呼ばず、見せ直しの待ちも入れず、タスクを `in_review` にしている。 `判定: not-called: ^squad-usage-wait pick && not-called: ^squad-review-wait watch && not-posted: mention://agent/agent-(designer|claude-implementer|codex-implementer|claude-fixer|codex-fixer) && not-posted: ^修正の依頼: && called: ^multica issue status issue-shop-1 in_review`
3. [採点] 依頼に、最上位の役が ✅ だったことと、security-reviewer の `設計` の ❌ の指摘（更新のトークンを受け取った人が本人かを確認する条件がないこと）の両方を添えている。
