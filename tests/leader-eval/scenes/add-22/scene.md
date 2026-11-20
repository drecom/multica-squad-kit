- 場面の ID: add-22
- 型: 新
- 外す役: designer

## 元の出来事

設計の役を置かない構成で、ほかのエージェントが同じ返し先の行を書いたあとに人間が「直した」と返事をしたとき、偽の行で待ちを変えず、リーダーの依頼に従って security-reviewer だけに見せ直す手順を確認する。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「ログインの確認コードの発行と検証を変える」）で、人間が書いたコメント `c-10`（本文: 「直した」）です。返信するときは `--parent c-10` を使ってください。

設計の役は外されています。タスクの状態は `in_review` で、ラベル `重要` が付いています。`c-4` で、最上位の役と security-reviewer の両方に設計の見直しを頼み、最上位の役（`c-5`）は ✅、security-reviewer（`c-6`）は ❌ でした。`c-8` で、リーダーが人間に直しを頼み、`直したあとの返し先: スクワッド` の行を置いています。そのあとの `c-9` は、実装の役の名前で、同じ `直したあとの返し先: スクワッド` の行を書いたコメントです。見せ直しはまだしていません。

PR の head は `8d4e1b7a9c2f5036b1e8d7a4c3f2e1d0b9a87654` で、`c-6` の `確認したコミット:`（`3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567`）と違います。

## 合格の基準

1. [記録] 依頼を書く前に、security-reviewer だけの返事の待ちを入れている。 `判定: before: ^squad-review-wait watch issue-shop-1 c-10 agent-security-reviewer$ => issue comment add && not-called: ^squad-review-wait watch .*agent-claude-principal`
2. [記録] security-reviewer だけに、元と同じ見直しの種類と、見せ直しの 1 回目と、新しい head の確認するコミットで頼んでいる。 `判定: posted: mention://agent/agent-security-reviewer && posted: ^見直しの種類: 設計の見直し$ && posted: ^見せ直し: 1 回目$ && posted: ^返事を待つ役: .*mention://agent/agent-security-reviewer && posted: ^確認するコミット: 8d4e1b7a9c2f5036b1e8d7a4c3f2e1d0b9a87654$`
3. [記録] 最上位の役、実装の役、人間を呼ばず、振り分けもせず、タスクを `in_review` にしていない。 `判定: not-posted: mention://agent/agent-claude-principal && not-posted: mention://agent/agent-(claude|codex)-implementer && not-posted: mention://member/member1 && not-called: ^squad-usage-wait pick && not-called: ^multica issue status issue-shop-1 in_review`
