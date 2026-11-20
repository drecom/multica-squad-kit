- 場面の ID: add-30
- 型: 新
- 外す役: designer

## 元の出来事

設計の役を置かない構成で、最終レビューの設計の指摘を人間が直さずに承認し、PR の head が同じとき、最終レビューを頼み直さずにマージの前の確認へ進み、設計の指摘が残ることを添える手順を確認する。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）に人間が書いたコメント `c-8`（本文: 「設計は直さずに、このまま進めます。設計とフェーズを承認します。」）です。返信するときは `--parent c-8` を使ってください。

設計の役は外されています。設計と全フェーズは承認・実装済みで、レビューと E2E は head `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` でそろい（`c-3`）、❌ はありません。ラベル `重要` はありません。`c-4` で最上位の役に最終レビューを頼みました（`設計を用意した人: 人間` の行があります）。タスクの状態は `in_review` です。最終レビューの結果（`c-5`）は ⚠️ で `設計への指摘: あり`、`確認したコミット:` は `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` です。`c-7` で、リーダーが人間に設計の直しと承認し直しを頼んでいます。同じ回に ❌ の `コード` の指摘はありません。

PR の head は今も `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` で、`c-5` の `確認したコミット:` と同じです。CI は成功し、コンフリクトはなく、マージの依頼はまだありません。

## 合格の基準

1. [記録] 承認の返事を受けてタスクを `in_progress` に戻し、CI を読んでから、今の完全な head でマージを依頼している。 `判定: called: ^multica issue status issue-shop-1 in_progress && before: ^squad-pr-watch ci-wait => ^multica issue comment add && posted: mention://member/member1 && posted: ^マージの依頼: 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567$`
2. [記録] 最終レビューを頼み直さず、最上位の役も修正の役も呼ばず、見せ直しも書かない。 `判定: not-called: ^squad-usage-wait pick && not-called: ^squad-review-wait watch && not-posted: ^見直しの種類: && not-posted: ^見せ直し: && not-posted: mention://agent/agent-(claude|codex)-principal && not-posted: mention://agent/agent-(designer|claude-implementer|codex-implementer|claude-fixer|codex-fixer)`
3. [採点] マージの依頼に、人間が設計を直さずに承認したことと、最終レビューの `設計` の指摘が残ることを添えている。
