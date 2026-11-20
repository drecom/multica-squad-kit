- 場面の ID: add-44
- 型: 新

## 元の出来事

設計の役を置く構成で、診断の `直す役: 設計の役` のあとに設計の役が直した設計を人間が承認し直したとき、承認し直した設計の実装を実装の役へ頼み、同じコメントに設計の承認し直しを理由とする行を置く。修正の依頼の行と人間の再開を理由とする行は置かない手順を確認する。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）に人間が書いたコメント `comment-9`（本文: 「設計を直して push した。設計とフェーズを承認し直します。」）です。返信するときは `--parent comment-9` を使ってください。

タスクの状態は `in_review` で、ラベル `重要` が付いており、`comment-m1` に `重要のマーク:` の行があります。実装の前に `comment-r1` で最上位の役に設計の見直しを頼み、結果（`comment-r2`）は指摘なしでした。`comment-4` で最上位の役に診断を頼み、診断（`comment-5`）は `直す役: 設計の役` でした。`comment-7` で、リーダーが設計の役に設計の変更（`設計の変更: 実装を始めたあと`）を頼み、設計の役が `comment-8` で設計を直して人間に承認を頼んでいます。診断を頼んだ失敗（同じ誤り テスト cart-badge-test）は、直ったと確認していない検証待ちです。

## 合格の基準

1. [記録] 承認の返事を受けてタスクを `in_progress` に戻し、実装の役を選ぶ pick に見積もりの語を添えず、実装の役をメンションして承認し直した設計の実装を頼み、設計の承認し直しの数え直しの行を置いている。 `判定: called: ^multica issue status issue-shop-1 in_progress && called: ^squad-usage-wait pick issue-shop-1 implement$ && not-called: ^multica issue label add && not-posted: ^重要のマーク: && posted: (?sm)\A(?=.*mention://agent/agent-(claude|codex)-implementer)(?=.*^数え直し: 同じ誤りのすべて。理由: 設計の承認し直し$)`
2. [記録] 人間の再開の数え直しも診断の数え直しも置かず、修正の依頼も同じ誤りの行も同じ部品の行も書かず、設計の役と修正の役と最上位の役を呼ばず、設計と PR の見直しを頼み直さない。 `判定: not-posted: ^数え直し: 同じ誤りのすべて。理由: 人間の再開 && not-posted: ^診断の数え直し: && not-posted: ^修正の依頼: && not-posted: ^同じ誤り: && not-posted: ^同じ部品: && not-posted: mention://agent/agent-(claude|codex)-principal && not-posted: mention://agent/agent-(designer|claude-fixer|codex-fixer) && not-posted: ^見直しの種類: && not-called: ^squad-review-wait watch`
3. [採点] 実装の役への依頼に、診断の結果（`comment-5`）へのリンクと、検証待ちの失敗を添えている。設計の文書を実装の役に直させず、診断した失敗を検証待ちのまま残し、直ったとは書いていない。
