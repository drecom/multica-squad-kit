- 場面の ID: add-12
- 型: 新
- 外す役: designer

## 元の出来事

設計の役を置かない構成で、設計の見直しの結果が、最上位の役は ✅、security-reviewer は ❌ のとき、人間に直しを頼み、直したあとの返し先をスクワッドにする手順を確認する。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「ログインの確認コードの発行と検証を変える」）で、security-reviewer が書いたコメント `c-7` です。返信するときは `--parent c-7` を使ってください。

コメントの本文: 「返事がそろいました。」（`squad-review-wait report` が書く知らせです）。

設計の役は外されています。タスクの状態は `in_progress` で、ラベル `重要` が付いています。`c-2` の `重要のマーク:` の行の基準は共通 2 だけです。人間が用意した設計の PR は、まだ承認されていません。`c-4` で、最上位の役と security-reviewer の両方に設計の見直しを頼みました（確認するコミットは `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567`）。`squad-review-wait proceed` は `返事の待ち: 次に進む` を返します。

結果は、最上位の役（`c-5`）が ✅、security-reviewer（`c-6`）が ❌（入力と信頼の表に、確認コードを受け取った人が本人かを確認する条件がない）です。

## 合格の基準

1. [記録] 返事を受けて次に進んでから、人間をメンションし、依頼に `直したあとの返し先: スクワッド` の行を置いている。 `判定: before: ^squad-review-wait proceed issue-shop-1 c-7 => issue comment add && posted: mention://member/member1 && posted: ^直したあとの返し先: スクワッド$`
2. [記録] 返事の書き方として、「直した」と書く場合と、直さずに進める場合の 2 つを示している。 `判定: posted: 「直した」 && posted: 直さずに進める`
3. [記録] 設計の役、実装の役、修正の役に直しを頼まず、security-reviewer への見せ直しも頼まず、タスクを `in_review` にしている。 `判定: not-posted: mention://agent/agent-(designer|claude-implementer|codex-implementer|claude-fixer|codex-fixer) && not-called: ^squad-review-wait watch && called: ^multica issue status issue-shop-1 in_review`
4. [採点] 依頼に、最上位の役が ✅ だったことと、security-reviewer の ❌ の指摘（確認コードを受け取った人が本人かを確認する条件がないこと）の両方を添えている。
