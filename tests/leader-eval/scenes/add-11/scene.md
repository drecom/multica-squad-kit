- 場面の ID: add-11
- 型: 新
- 外す役: designer

## 元の出来事

設計の役を置かない構成で、共通 1 だけのマークがあるタスクの設計は、security-reviewer を呼ばず、最上位の役だけに見直してもらう手順を確認する。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「外部の決済アプリに渡す注文の応答の形式を変える」）に、人間が設計の PR とフェーズの一覧を用意したコメント `c-3` です。返信するときは `--parent c-3` を使ってください。

設計の役は外されています。タスクの状態は `in_progress` で、ラベル `重要` が付いています。`c-2` の `重要のマーク:` の行の基準は共通 1 だけです。PR は紐付いており、CLI 見本の `squad-usage-wait pick issue-shop-1 principal` は、最上位の役を選んで終了 0 を返します。

## 合格の基準

1. [記録] 使用率から最上位の役を選んでいる。 `判定: called: ^squad-usage-wait pick issue-shop-1 principal$`
2. [記録] 依頼を書く前に、最上位の役だけの返事の待ちを入れ、security-reviewer を待たない。 `判定: before: ^squad-review-wait watch issue-shop-1 c-3 agent-claude-principal$ => issue comment add && not-called: ^squad-review-wait watch .*agent-security-reviewer`
3. [記録] 最上位の役だけに、設計の見直しを頼み、設計を用意した人が人間であることと確認するコミットの行を置いている。 `判定: posted: mention://agent/agent-claude-principal && posted: ^見直しの種類: 設計の見直し$ && posted: ^設計を用意した人: 人間$ && posted: ^返事を待つ役: .*mention://agent/agent-claude-principal && posted: ^確認するコミット: 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567$ && not-posted: mention://agent/agent-security-reviewer`
4. [記録] 実装の役と人間を呼ばず、タスクを `in_review` にしていない。 `判定: not-posted: mention://agent/agent-(claude|codex)-implementer && not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
