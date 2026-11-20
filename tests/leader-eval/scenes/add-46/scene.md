- 場面の ID: add-46
- 型: 新

## 元の出来事

`squad-review-next decide` が `fix` で人間を呼んだ回に人間が「進める」と答えたら、`decide` を流し直さず、`answer` のあとに `--round` なしで `pick` を流し、修正の依頼を手で書く。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` の人間のコメント `comment-5` で起きました。返信は `--parent comment-5` を使います。

コメントの本文: 「進めてください。」

修正の依頼は、使用率の待ちが通算 24 時間を超えたため止まっています。人間を呼ぶコメント `comment-4` は、コードレビューの役が `decide` で書いたもので、`前の回: round-1` の行があります。タスクは `in_review` で、人間の名前は `Owner` です。`round-1` のレビューは今の head `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` で ❌ の必須の指摘を 1 件返しています（`comment-2`）。このタスクに `修正の依頼:` の行はまだありません。`squad-review-next decide issue-shop-1 round-1` は `次の依頼: 書き済み` を返します。

## 合格の基準

1. [記録] 答えを、工程と答えの語と返事のコメントの ID を渡した `answer` で記録し、同じ回の `decide` を流し直していない。 `判定: called: ^squad-usage-wait answer issue-shop-1 fix 進める comment-5( |$) && not-called: ^squad-review-next decide && not-posted: ^使用率の待ちの延長: && not-posted: ^使用率の答え:`
2. [記録] `answer` のあとに、`--round` を渡さずに修正の工程で `pick` を流している。 `判定: before: ^squad-usage-wait answer issue-shop-1 fix 進める comment-5( |$) => ^squad-usage-wait pick issue-shop-1 fix( |$) && not-called: ^squad-usage-wait pick .*--round`
3. [記録] `pick` のあとに、`pick` が選んだ修正の役へ依頼を手で書いている。依頼に `修正の依頼: 1 回目`、`pick` の `振り分け:` の行を置き、`直す指摘:` の行は置かず、人間を呼び直さず、終わった `squad-dispatch-pick` も使わない。 `判定: before: ^squad-usage-wait pick issue-shop-1 fix( |$) => ^multica issue comment add issue-shop-1 && posted: mention://agent/agent-claude-fixer && posted: ^修正の依頼: 1 回目$ && posted: ^振り分け: .+人間の答えで進める（期限 2026-01-11T14:00:00Z、答えのタスク issue-shop-1）。工程: fix$ && not-posted: ^直す指摘: && not-posted: mention://member/ && not-called: ^squad-dispatch-pick`
4. [採点] 依頼に、`round-1` のレビューの ❌ の指摘（バッジが 100 以上で崩れること）を添えている。`decide` が書き済みで終わったと読んで止まらず、依頼まで書いている。
