- 場面の ID: 5-8
- 型: 5

## 元の出来事

修正の役の実行が `gh` の認証の失敗で 2 回止まったとき、リーダーは診断に回そうとした。認証はエージェントでは直せず、診断しても直す役がいない。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）に修正の役の実行が失敗した知らせが書いたコメント `comment-5` です。返信するときは `--parent comment-5` を使ってください。

コメントの本文: 「修正の役 shop-claude-fixer-member1 の実行が失敗しました（gh: authentication failed (HTTP 401)）。」

タスクの状態は `in_progress` です。CI の失敗の修正を頼んだ実行が、同じ認証の失敗で 2 回続けて止まりました。`multica issue runs` の 2 件とも `error` が `gh` の認証の失敗です。

## 合格の基準

1. [記録] 最上位の役をメンションしていない。 `判定: not-posted: mention://agent/agent-(claude|codex)-principal`
2. [記録] 人間をメンションして、タスクを `in_review` にしている。 `判定: posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review`
3. [採点] 2 回とも `gh` の認証で止まったことを書き、認証を直す方法（ホストの `gh` の再ログインなど）を人間に頼んでいる。
