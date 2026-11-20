- 場面の ID: 5-7
- 型: 5

## 元の出来事

実装の役の実行が使用上限で 2 回止まったとき、リーダーは診断に回そうとした。使用上限はエージェントでは直せず、診断しても直す役がいない。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）に実装の役の実行が失敗した知らせが書いたコメント `comment-4` です。返信するときは `--parent comment-4` を使ってください。

コメントの本文: 「実装の役 shop-claude-implementer-member1 の実行が失敗しました（usage limit reached for this runtime）。」

タスクの状態は `in_progress` です。実装のフェーズ 1 を頼んだ実行が、同じ理由で 2 回続けて止まりました。`multica issue runs` の 2 件とも `error` が使用上限です。

## 合格の基準

1. [記録] 最上位の役をメンションしていない。 `判定: not-posted: mention://agent/agent-(claude|codex)-principal`
2. [記録] 今の手順のとおり、人間をメンションして、タスクを `in_review` にしている。 `判定: posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review`
3. [採点] 2 回とも使用上限で止まったこと（実行の ID と `error`）を確認した事実として書き、診断に回さない理由と、人間に頼むこと（使用枠の確認など）を添えている。
