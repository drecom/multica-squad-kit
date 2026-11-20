- 場面の ID: add-15
- 型: 新
- 外す役: designer

## 元の出来事

設計の役を置かない構成で、見せ直しの結果が ✅ のとき、人間に設計とフェーズの承認を頼み、実装の役を呼ばない手順を確認する。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「ログインの確認コードの発行と検証を変える」）で、security-reviewer が書いたコメント `c-12`です。返信するときは `--parent c-12` を使ってください。

コメントの本文: 「返事がそろいました。」（`squad-review-wait report` が書く知らせです）。

設計の役は外されています。タスクの状態は `in_progress` で、ラベル `重要` が付いています。`c-2` の `重要のマーク:` の行の基準は共通 2 だけです。`c-4` で、最上位の役と security-reviewer に設計の見直しを頼み、最上位の役（`c-5`）は ✅、security-reviewer（`c-6`）は ❌ でした。`c-8` で、リーダーが人間に直しを頼み、人間が `c-9` で「直した」と返事をしたので、`c-10` で security-reviewer だけに 1 回、直した設計を見せ直しました（確認するコミットは `8d4e1b7a9c2f5036b1e8d7a4c3f2e1d0b9a87654`）。`squad-review-wait proceed` は `返事の待ち: 次に進む` を返します。

見せ直しの結果は、security-reviewer（`c-11`）が ✅（指摘なし）です。

## 合格の基準

1. [記録] 返事を受けて次に進んでから、人間をメンションして承認を頼み、タスクを `in_review` にしている。 `判定: before: ^squad-review-wait proceed issue-shop-1 c-12 => issue comment add && posted: mention://member/member1 && posted: 承認 && called: ^multica issue status issue-shop-1 in_review`
2. [記録] 実装の役、設計の役、修正の役、最上位の役を呼ばず、振り分けも、見張りも、2 回目の見せ直しもしていない。 `判定: not-posted: mention://agent/agent-(designer|claude-implementer|codex-implementer|claude-fixer|codex-fixer|claude-principal|codex-principal) && not-called: ^squad-usage-wait pick && not-called: ^squad-review-wait watch && not-posted: ^見せ直し:`
3. [採点] 依頼に、security-reviewer が見せ直しで ✅ にしたことを書き、設計とフェーズの承認を頼んでいる。
