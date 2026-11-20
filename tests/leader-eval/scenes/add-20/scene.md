- 場面の ID: add-20
- 型: 新
- 外す役: designer

## 元の出来事

設計の役を置かない構成で、人間が直さずに進めると返事をしたとき、見せ直さず、承認として実装へ進み、security の ❌ が残ることを添える手順を確認する。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「ログインの確認コードの発行と検証を変える」）で、人間が書いたコメント `c-9`（本文: 「直さずに進めます。設計とフェーズを承認します。」）です。返信するときは `--parent c-9` を使ってください。

設計の役は外されています。タスクの状態は `in_review` で、ラベル `重要` が付いています。`c-4` で、最上位の役と security-reviewer の両方に設計の見直しを頼み、最上位の役（`c-5`）は ✅、security-reviewer（`c-6`）は ❌ でした。`c-8` で、リーダーが人間に直しを頼み、`直したあとの返し先: スクワッド` の行を置いています。見せ直しはまだしていません。設計のフェーズは 1 つで、見積もりは `小さい` です。

## 合格の基準

1. [記録] 見せ直しを頼まず、security-reviewer の返事の待ちも入れていない。 `判定: not-called: ^squad-review-wait watch && not-posted: mention://agent/agent-security-reviewer && not-posted: ^見せ直し:`
2. [記録] 承認として、実装の役を選び、実装のフェーズ 1 を頼んでいる。人間を呼ばず、タスクを `in_review` にしていない。 `判定: called: ^squad-usage-wait pick issue-shop-1 implement 小さい$ && posted: mention://agent/agent-claude-implementer && posted: フェーズ 1 && not-posted: mention://member/member1 && not-called: ^multica issue status issue-shop-1 in_review`
3. [採点] 依頼に、security-reviewer の ❌ が残ったまま、人間の決定で進めることを 1 文で添えている。
