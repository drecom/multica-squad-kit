- 場面の ID: add-29
- 型: 新
- 外す役: designer

## 元の出来事

設計の役を置かない構成で、最終レビューの設計の指摘を人間が直して承認し直し、PR の head が変わったとき、今の head で最終レビューを頼み直し、見せ直しの行を置かない手順を確認する。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）に人間が書いたコメント `c-8`（本文: 「設計を直して push した。設計とフェーズを承認し直します。」）です。返信するときは `--parent c-8` を使ってください。

設計の役は外されています。設計は人間が用意し、実装の前に `c-d1` で最上位の役に設計の見直しを頼み、結果（`c-d2`）は指摘なしでした。設計と全フェーズは承認・実装済みで、レビューと E2E は head `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` でそろい（`c-3`）、❌ はありません。ラベル `重要` と `重要のマーク:` の行はありません。`c-4` で最上位の役に最終レビューを頼みました（`設計を用意した人: 人間` の行があります）。タスクの状態は `in_review` です。最終レビューの結果（`c-5`）は ⚠️ で `設計への指摘: あり`、`確認したコミット:` は `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` です。`c-7` で、リーダーが人間に設計の直しと承認し直しを頼んでいます。同じ回に ❌ の `コード` の指摘はありません。

PR の head は今 `8d4e1b7a9c2f5036b1e8d7a4c3f2e1d0b9a87654` で、`c-5` の `確認したコミット:` と違います。

## 合格の基準

1. [記録] 承認の返事を受けてタスクを `in_progress` に戻し、実装を始めたあとの設計の変更だが設計の見直しの結果がすでにあるので、ラベルを付けず、`手戻りの見直し: 頼まない。合図: 実装を始めたあとの設計の変更` の行を置き、実装した系統と違う最上位の役を選び、今の head で最終レビューを頼んでいる。 `判定: called: ^multica issue status issue-shop-1 in_progress && not-called: ^multica issue label add && not-posted: ^重要のマーク: && posted: ^手戻りの見直し: 頼まない。合図: 実装を始めたあとの設計の変更 && called: ^multica issue runs issue-shop-1 && called: ^squad-usage-wait pick issue-shop-1 principal Claude$ && called: ^squad-review-wait watch issue-shop-1 c-8 agent-codex-principal && posted: (?sm)\A(?=.*mention://agent/agent-codex-principal)(?=.*^数え直し: 同じ誤りのすべて。理由: 設計の承認し直し$) && posted: ^見直しの種類: 最終レビュー$ && posted: ^確認するコミット: 8d4e1b7a9c2f5036b1e8d7a4c3f2e1d0b9a87654$ && posted: ^返事を待つ役:.*mention://agent/agent-codex-principal`
2. [記録] 設計の見直しの結果がすでにあるので設計と PR の見直しを頼まず、依頼に `見せ直し:` の行を置かず、人間にマージを依頼せず、修正の役を呼ばない。 `判定: not-posted: ^見直しの種類: 設計と PR の見直し && not-posted: ^見せ直し: && not-posted: ^マージの依頼: && not-posted: mention://member/member1 && not-posted: mention://agent/agent-(claude|codex)-fixer && not-posted: mention://agent/agent-(designer|claude-implementer|codex-implementer)`
3. [採点] 依頼が、直した設計の確認ではなく、今の head の普通の最終レビューになっている。
