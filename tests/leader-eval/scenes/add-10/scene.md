- 場面の ID: add-10
- 型: 新
- 外す役: designer

## 元の出来事

設計の役を置かない構成で、共通 2（安全の仕組みに触れる）のマークがあるタスクの設計を、最上位の役と security-reviewer の両方に 1 つの依頼で見直してもらう手順を確認する。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「ログインの確認コードの発行と検証を変える」）に、人間が設計の PR とフェーズの一覧を用意したコメント `c-3` です。返信するときは `--parent c-3` を使ってください。

設計の役は外されています。タスクの状態は `in_progress` で、ラベル `重要` が付いています。`c-2` の `重要のマーク:` の行の基準は共通 2 だけです。PR は紐付いており、CLI 見本の `squad-usage-wait pick issue-shop-1 principal` は、最上位の役を選んで終了 0 を返します。

## 合格の基準

1. [記録] 使用率から最上位の役を選んでいる。 `判定: called: ^squad-usage-wait pick issue-shop-1 principal$`
2. [記録] 依頼を書く前に、最上位の役と security-reviewer の返事の待ちを、1 回の呼び出しで入れている。 `判定: before: ^squad-review-wait watch issue-shop-1 \S+ (agent-claude-principal agent-security-reviewer|agent-security-reviewer agent-claude-principal)$ => issue comment add`
3. [記録] 依頼に、設計の見直し、設計を用意した人が人間であること、2 つの役を並べた返事を待つ役、確認するコミットの行がある。 `判定: posted: ^見直しの種類: 設計の見直し$ && posted: ^設計を用意した人: 人間$ && posted: ^返事を待つ役: (?=.*mention://agent/agent-claude-principal)(?=.*mention://agent/agent-security-reviewer) && posted: ^確認するコミット: 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567$`
4. [採点] 2 つの役への依頼を、1 つのコメントにしている。役ごとに依頼を分けていない。
5. [記録] 実装の役と人間を呼ばず、タスクを `in_review` にしていない。 `判定: not-posted: mention://agent/agent-(claude|codex)-implementer && not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
