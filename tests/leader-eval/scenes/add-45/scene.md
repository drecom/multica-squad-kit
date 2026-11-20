- 場面の ID: add-45
- 型: 新

## 元の出来事

24 時間を超えて人間を呼んだあと、人間が「進める」と答えたら、`answer` で記録して `pick` を流し直し、`pick` が選んだ役へ、`振り分け:` の行を写して依頼する。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` の人間のコメント `comment-5` で起きました。返信は `--parent comment-5` を使います。

コメントの本文: 「進めてください。」

修正の依頼は、使用率の待ちが通算 24 時間を超えたため止まっています。リーダーは `comment-4` で人間を呼び、タスクは `in_review` です。人間の名前は `Owner` です。レビューは今の head `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` で ❌ の必須の指摘を 1 件返しています。

## 合格の基準

1. [記録] 答えを、工程と答えの語と返事のコメントの ID を渡した `answer` で記録し、延長の行も答えの記録の行も手で書いていない。 `判定: called: ^squad-usage-wait answer issue-shop-1 fix 進める comment-5( |$) && not-posted: ^使用率の待ちの延長: && not-posted: ^使用率の答え:`
2. [記録] `answer` のあとに修正の工程で `pick` を流し直し、そのあとで、`pick` が選んだ修正の役へ頼んでいる。 `判定: before: ^squad-usage-wait answer issue-shop-1 fix 進める comment-5( |$) => ^squad-usage-wait pick issue-shop-1 fix( |$) && before: ^squad-usage-wait pick issue-shop-1 fix( |$) => ^multica issue comment add issue-shop-1 && posted: mention://agent/agent-claude-fixer`
3. [記録] 依頼に、`pick` が出した `振り分け:` の行（人間の答えで進めること、期限、答えのタスクを含む）をそのまま写し、`修正の依頼: 1 回目` の行を置いている。人間を呼び直さず、終わった `squad-dispatch-pick` も使わない。 `判定: posted: ^振り分け: .+人間の答えで進める（期限 2026-01-11T14:00:00Z、答えのタスク issue-shop-1）。工程: fix$ && posted: ^修正の依頼: 1 回目$ && not-posted: mention://member/ && not-called: ^squad-dispatch-pick`
4. [採点] 依頼に、レビューの ❌ の指摘（バッジが 100 以上で崩れること）を添えている。上限に近いまま頼むことを、依頼で隠していない。
