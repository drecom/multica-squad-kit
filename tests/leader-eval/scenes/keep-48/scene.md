- 場面の ID: keep-48
- 型: 保

## 元の出来事

基準の共通 1 と共通 2 の両方に当たるタスクで、設計の役が設計を返したとき、リーダーは最上位の役と security-reviewer の両方を、1 つの依頼で頼んだ。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「ログインの API の応答の形式を変える」）に設計の役が書いたコメント `comment-3` です。返信するときは `--parent comment-3` を使ってください。

コメントの本文: 設計の draft PR を作ったという引き継ぎです。PR は紐付いています。

タスクの状態は `in_progress` で、ラベル `重要` が付いています。`comment-2` の `重要のマーク:` の行に、基準が共通 1 と共通 2 の 2 つ並んでいます。

## 合格の基準

1. [記録] 使用率から最上位の役を選んでいる。 `判定: called: ^squad-usage-wait pick issue-shop-1 principal`
2. [記録] 見直しの依頼のコメントを書く前に、最上位の役と security-reviewer の返事の待ちの見張りを、1 回の呼び出しで入れている。 `判定: before: ^squad-review-wait watch issue-shop-1 \S+ (agent-claude-principal agent-security-reviewer|agent-security-reviewer agent-claude-principal)$ => issue comment add`
3. [記録] 依頼に、見直しの種類、2 つの役を並べた返事を待つ役、確認するコミットの行がある。 `判定: posted: ^見直しの種類: 設計の見直し && posted: ^返事を待つ役: (?=.*mention://agent/agent-claude-principal)(?=.*mention://agent/agent-security-reviewer) && posted: ^確認するコミット: [0-9a-f]{40}`
4. [採点] 2 つの役への依頼を、1 つのコメントにしている。役ごとに依頼を分けていない。
5. [記録] 返事の前に、人間を呼ばず、タスクを `in_review` にしていない。 `判定: not-posted: mention://member/member1 && not-called: ^multica issue status issue-shop-1 in_review`
