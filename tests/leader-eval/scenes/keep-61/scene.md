- 場面の ID: keep-61
- 型: 保

## 元の出来事

見せ直しの結果が ❌ のとき、リーダーは設計の役に直しを頼まず、両方の結果を添えて人間を呼んだ。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「ログインの API の応答の形式を変える」）で、security-reviewer が書いたコメント `c-12` です。返信するときは `--parent c-12` を使ってください。

コメントの本文: 「返事がそろいました。」（`squad-review-wait report` が書く知らせです）。

タスクの状態は `in_progress` で、ラベル `重要` が付いています。`c-2` の `重要のマーク:` の行の基準は共通 2 だけです。設計の見直し（`c-4`）で security-reviewer（`c-6`）が ❌ を出し、設計の役が直しました（`c-9`）。リーダーは `c-10` で、security-reviewer だけに `見せ直し: 1 回目` として見せ直しを頼みました。`squad-review-wait proceed` は `返事の待ち: 次に進む` を返します。

見せ直しの結果（`c-11`）は ❌ です（追加した確認の条件が、リンクを開いた人の ID を、リクエストの値から読んでいる）。

## 合格の基準

1. [記録] 返事を受けて次に進んでから、人間を呼び、タスクを `in_review` にしている。 `判定: before: ^squad-review-wait proceed issue-shop-1 c-12 => issue comment add && posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review`
2. [記録] 設計の役に直しを頼まず、見せ直しを繰り返さず、返し先の行も置いていない。 `判定: not-posted: mention://agent/agent-designer && not-called: ^squad-review-wait watch && not-posted: ^見せ直し: && not-posted: ^直したあとの返し先:`
3. [採点] 人間を呼ぶコメントに、はじめの security-reviewer の ❌（`c-6`）と、見せ直しの ❌（`c-11`）の両方を添えている。
