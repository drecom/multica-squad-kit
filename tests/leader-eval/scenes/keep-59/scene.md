- 場面の ID: keep-59
- 型: 保

## 元の出来事

security の ❌ を設計の役が直して返したとき、リーダーは security-reviewer だけに、1 回目の見せ直しとして頼んだ。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「ログインの API の応答の形式を変える」）で、設計の役 が書いたコメント `c-9` です。返信するときは `--parent c-9` を使ってください。

コメントの本文: 設計を直して push したという、スクワッドへの引き継ぎです。確認するコミットは `8b1d4e6f0a2c3d5e7f9012345678abcdef012345` です。

タスクの状態は `in_progress` で、ラベル `重要` が付いています。`c-2` の `重要のマーク:` の行の基準は共通 2 だけです。設計の見直し（`c-4`）の結果は、最上位の役（`c-5`）が ✅、security-reviewer（`c-6`）が ❌ でした。リーダーは `c-8` で、設計の役に `直したあとの返し先: スクワッド` の依頼を出しました。見せ直しは、まだ 1 回もしていません。

## 合格の基準

1. [記録] 依頼の前に、security-reviewer だけの返事の待ちの見張りを入れ、最上位の役を選んでいない。 `判定: before: ^squad-review-wait watch issue-shop-1 c-9 agent-security-reviewer$ => issue comment add && not-called: ^squad-review-wait watch .*agent-claude-principal && not-called: ^squad-usage-wait pick issue-shop-1 principal`
2. [記録] 依頼に、元と同じ見直しの種類、`見せ直し: 1 回目`、security-reviewer だけの返事を待つ役、直したコミットを置いている。 `判定: posted: ^見直しの種類: 設計の見直し$ && posted: ^見せ直し: 1 回目$ && posted: ^返事を待つ役: (?!.*mention://agent/agent-claude-principal).*mention://agent/agent-security-reviewer && posted: ^確認するコミット: 8b1d4e6f0a2c3d5e7f9012345678abcdef012345`
3. [記録] 人間を呼ばず、タスクを `in_review` にしていない。 `判定: not-posted: mention://member/member1 && not-called: ^multica issue status issue-shop-1 in_review`
