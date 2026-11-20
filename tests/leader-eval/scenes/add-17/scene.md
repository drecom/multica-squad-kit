- 場面の ID: add-17
- 型: 新
- 外す役: designer

## 元の出来事

設計の役を置かない構成で、人間が「直した」と返事をしても、PR の head が security-reviewer の ❌ のコミットのままなら、見せ直さず、直したコミットがないことを添えて人間を呼ぶ手順を確認する。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「ログインの確認コードの発行と検証を変える」）で、人間が書いたコメント `c-9`（本文: 「直した」）です。返信するときは `--parent c-9` を使ってください。

設計の役は外されています。タスクの状態は `in_review` で、ラベル `重要` が付いています。`c-4` で、最上位の役と security-reviewer の両方に設計の見直しを頼み、最上位の役（`c-5`）は ✅、security-reviewer（`c-6`）は ❌ でした。`c-8` で、リーダーが人間に直しを頼み、`直したあとの返し先: スクワッド` の行を置いています。見せ直しはまだしていません。

PR の head は `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` で、`c-6` の `確認したコミット:`（`3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567`）と同じです。

## 合格の基準

1. [記録] 見せ直しを頼まず、どの役も呼ばず、待ちも入れない。人間をメンションし、タスクを `in_review` にしている。 `判定: not-called: ^squad-review-wait watch && not-posted: ^見せ直し: && not-posted: mention://agent/ && posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review`
2. [採点] 依頼に、PR の head が security-reviewer の ❌ を出したコミットのままで、直したコミットがないことを書いている。
