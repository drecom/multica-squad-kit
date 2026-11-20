- 場面の ID: keep-55
- 型: 保

## 元の出来事

設計の見直しで、最上位の役だけに指摘があり security が ✅ のとき、リーダーは人間を呼ばず、両方の結果を添えて設計の役に直しを頼んだ。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「ログインの API の応答の形式を変える」）で、security-reviewer が書いたコメント `c-7` です。返信するときは `--parent c-7` を使ってください。

コメントの本文: 「返事がそろいました。」（`squad-review-wait report` が書く知らせです）。

タスクの状態は `in_progress` で、ラベル `重要` が付いています。`c-2` の `重要のマーク:` の行の基準は共通 2 だけです。設計の役が出した設計は、まだ人間に承認されていません。`c-4` で、最上位の役と security-reviewer の両方に設計の見直しを頼みました（確認するコミットは `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567`）。`squad-review-wait proceed` は `返事の待ち: 次に進む` を返します。

結果は、最上位の役（`c-5`）が ❌（設計の文書に、トークンの期限を延ばせる上限がない）、security-reviewer（`c-6`）が ✅ です。

## 合格の基準

1. [記録] 返事を受けて次に進んでから、設計の役に直しを頼んでいる。 `判定: before: ^squad-review-wait proceed issue-shop-1 c-7 => issue comment add && posted: mention://agent/agent-designer`
2. [記録] 人間を呼ばず、in_review にせず、見せ直しの行も、security-reviewer の見張りも置かない。 `判定: not-posted: mention://member/member1 && not-called: ^multica issue status issue-shop-1 in_review && not-posted: ^直したあとの返し先: && not-called: ^squad-review-wait watch`
3. [採点] 直しの依頼に、最上位の役の指摘（期限を延ばせる上限がないこと）と、security-reviewer が ✅ だったことの両方を添えている。
