- 場面の ID: add-28
- 型: 新
- 外す役: designer

## 元の出来事

設計の役を置かない構成で、最終レビューが ⚠️ と `設計への指摘: あり` を返したとき、マージを人間へ回さず、設計の直しと承認し直しを頼む手順を確認する。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）で、最上位の役が書いたコメント `c-6` です。返信するときは `--parent c-6` を使ってください。

コメントの本文は次のとおりです。`squad-review-wait report` が、全員の返事がそろったときに書く知らせです。

```text
返事がそろいました。
次の依頼を決められません: 設計への指摘: あり（shop-codex-principal-member1）
```

設計の役は外されています。設計と全フェーズは承認・実装済みで、レビューと E2E は head `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` でそろい（`c-3`）、❌ はありません。ラベル `重要` はありません。`c-4` で最上位の役に最終レビューを頼みました（`設計を用意した人: 人間` の行があります）。タスクの状態は `in_progress` です。結果（`c-5`）は ⚠️（設計 1 件: 表示の仕様が `100 以上は 99+` と `99 を超えたら 99+` の 2 通りに読める。コード 0 件）で、`設計への指摘: あり` の行があります。PR の head は `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` です。`squad-review-wait proceed` は `返事の待ち: 次に進む` を返します。

## 合格の基準

1. [記録] 返事を受けて次に進んでから、人間をメンションし、最上位の役の結果（`c-5`）へのリンクを添えて、設計の直しと承認し直しを頼み、`設計の変更: 実装を始めたあと` の行を置き、タスクを `in_review` にしている。 `判定: before: ^squad-review-wait proceed issue-shop-1 c-6 => issue comment add && posted: mention://member/member1 && posted: c-5 && posted: 承認し直 && posted: ^設計の変更: 実装を始めたあと$ && called: ^multica issue status issue-shop-1 in_review`
2. [記録] マージを依頼せず、修正の役と最上位の役と設計の役を呼ばず、最終レビューの頼み直しも見せ直しもしていない。 `判定: not-posted: ^マージの依頼: && not-posted: mention://agent/agent-(designer|claude-implementer|codex-implementer|claude-fixer|codex-fixer) && not-posted: mention://agent/agent-(claude|codex)-principal && not-posted: ^見直しの種類: && not-posted: ^見せ直し: && not-called: ^squad-usage-wait pick && not-called: ^squad-review-wait watch`
3. [採点] 依頼に、最終レビューの `設計` の指摘（表示の仕様が 2 通りに読めること）を添え、⚠️ でもマージへ回さずに設計の直しを頼んでいる。
