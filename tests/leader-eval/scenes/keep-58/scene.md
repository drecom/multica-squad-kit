- 場面の ID: keep-58
- 型: 保

## 元の出来事

設計の見直しで security が ⚠️ だけのとき、リーダーは設計の役に直しを頼み、見せ直しの行を置かず、security に見せ直さなかった。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「ログインの API の応答の形式を変える」）で、security-reviewer が書いたコメント `c-7` です。返信するときは `--parent c-7` を使ってください。

コメントの本文: 「返事がそろいました。」（`squad-review-wait report` が書く知らせです）。

タスクの状態は `in_progress` で、ラベル `重要` が付いています。`c-2` の `重要のマーク:` の行の基準は共通 2 だけです。設計の役が出した設計は、まだ人間に承認されていません。`c-4` で、最上位の役と security-reviewer の両方に設計の見直しを頼みました（確認するコミットは `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567`）。`squad-review-wait proceed` は `返事の待ち: 次に進む` を返します。

結果は、最上位の役（`c-5`）が ✅、security-reviewer（`c-6`）が ⚠️（推奨 1 件。再設定のリンクを使い終えたあとの扱いを、設計の文書に 1 文足すとよい）です。❌ はありません。

## 合格の基準

1. [記録] 返事を受けて次に進んでから、設計の役に直しを頼んでいる。 `判定: before: ^squad-review-wait proceed issue-shop-1 c-7 => issue comment add && posted: mention://agent/agent-designer`
2. [記録] `直したあとの返し先:` の行を置かず、security-reviewer の見張りも入れず、人間を呼ばず、`in_review` にもしていない。 `判定: not-posted: ^直したあとの返し先: && not-called: ^squad-review-wait watch && not-posted: mention://member/member1 && not-called: ^multica issue status issue-shop-1 in_review`
3. [採点] 直しの依頼に、security-reviewer の ⚠️ の指摘を添え、直したあとは人間に承認を頼むよう伝えている。
