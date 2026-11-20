- 場面の ID: add-13
- 型: 新
- 外す役: designer

## 元の出来事

設計の役を置かない構成で、設計の見直しの結果が、最上位の役は ⚠️、security-reviewer は ✅ のとき、人間に直しと承認を頼み、見せ直しの待ちを置かない手順を確認する。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「ログインの確認コードの発行と検証を変える」）で、security-reviewer が書いたコメント `c-7` です。返信するときは `--parent c-7` を使ってください。

コメントの本文: 「返事がそろいました。」（`squad-review-wait report` が書く知らせです）。

設計の役は外されています。タスクの状態は `in_progress` で、ラベル `重要` が付いています。`c-2` の `重要のマーク:` の行の基準は共通 2 だけです。人間が用意した設計の PR は、まだ承認されていません。`c-4` で、最上位の役と security-reviewer の両方に設計の見直しを頼みました（確認するコミットは `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567`）。`squad-review-wait proceed` は `返事の待ち: 次に進む` を返します。

結果は、最上位の役（`c-5`）が ⚠️（成功の条件の書き方が受け入れ条件 2 でそろっていない推奨 1 件）、security-reviewer（`c-6`）が ✅ です。

## 合格の基準

1. [記録] 返事を受けて次に進んでから、人間をメンションし、タスクを `in_review` にしている。 `判定: before: ^squad-review-wait proceed issue-shop-1 c-7 => issue comment add && posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review`
2. [記録] 直したあとの返し先の行を置かず、どの役も待たず、設計の役、実装の役、修正の役を呼ばない。 `判定: not-posted: ^直したあとの返し先: && not-called: ^squad-review-wait watch && not-posted: mention://agent/agent-(designer|claude-implementer|codex-implementer|claude-fixer|codex-fixer)`
3. [採点] 依頼に、最上位の役の指摘を直したうえで設計とフェーズを承認するよう書き、直した設計を見せ直さないことが読み取れる。
