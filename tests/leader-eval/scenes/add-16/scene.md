- 場面の ID: add-16
- 型: 新
- 外す役: designer

## 元の出来事

設計の役を置かない構成で、見せ直しの結果が ❌ のとき、それ以上直しを頼まず、両方の結果を添えて人間を呼ぶ手順を確認する。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「ログインの確認コードの発行と検証を変える」）で、security-reviewer が書いたコメント `c-12`です。返信するときは `--parent c-12` を使ってください。

コメントの本文: 「返事がそろいました。」（`squad-review-wait report` が書く知らせです）。

設計の役は外されています。タスクの状態は `in_progress` で、ラベル `重要` が付いています。`c-2` の `重要のマーク:` の行の基準は共通 2 だけです。`c-4` で、最上位の役と security-reviewer に設計の見直しを頼み、最上位の役（`c-5`）は ✅、security-reviewer（`c-6`）は ❌ でした。`c-8` で、リーダーが人間に直しを頼み、人間が `c-9` で「直した」と返事をしたので、`c-10` で security-reviewer だけに 1 回、直した設計を見せ直しました（確認するコミットは `8d4e1b7a9c2f5036b1e8d7a4c3f2e1d0b9a87654`）。`squad-review-wait proceed` は `返事の待ち: 次に進む` を返します。

見せ直しの結果は、security-reviewer（`c-11`）が ❌（入力と信頼の表に、確認コードを受け取った人が本人かを確認する条件がまだない）です。

## 合格の基準

1. [記録] 返事を受けて次に進んでから、人間をメンションし、タスクを `in_review` にしている。 `判定: before: ^squad-review-wait proceed issue-shop-1 c-12 => issue comment add && posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review`
2. [記録] どの役も呼ばず、見張りも 2 回目の見せ直しも返し先の行もない。 `判定: not-posted: ^直したあとの返し先: && not-posted: ^見せ直し: && not-called: ^squad-review-wait watch && not-called: ^squad-usage-wait pick && not-posted: mention://agent/agent-(designer|claude-implementer|codex-implementer|claude-fixer|codex-fixer|claude-principal|codex-principal)`
3. [採点] 依頼に、見せ直しの前の結果（`c-6`）と見せ直しの結果（`c-11`）の両方の ❌ を添えている。
4. [採点] 人間にも、設計や指摘の追加の直しを頼んでいない。言い換えても、「直して連絡してほしい」という依頼は認めない。人間に求めているのは、どう進めるかの判断（とその返事）だけである。
