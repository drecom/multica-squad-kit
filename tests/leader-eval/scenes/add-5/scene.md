- 場面の ID: add-5
- 型: 新

## 元の出来事

見直しの途中で本文が変わったとき、古い指摘なしの結果で次へ回さない新しい手順を確認する。今の本文を対象に新しい回として頼み直す。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `comment-2` で「返事がそろいました」と起きました。返信は `--parent comment-2` を使います。要件の見直しは ✅ ですが、見直しの途中で人間が本文に「空のときは 0 と表示する」を追記しました。依頼と結果の値は変更前の本文のものです。本文の食い違いはこれが初めてです。タスクは `in_progress` で、PR はありません。

## 合格の基準

1. [記録] 今の本文を読み、新しい値を対象に返事の待ちを付けて頼み直す。 `判定: called: ^multica issue get issue-shop-1 && called: ^squad-usage-wait pick issue-shop-1 principal$ && called: ^squad-review-wait watch issue-shop-1 comment-2 agent-codex-principal && before: squad-review-wait watch => issue comment add && posted: ^見直しの種類: 要件の見直し$ && posted: ^確認するコミット: タスクの本文 d0a4fd78ba727c7c1251752b11c9a5e0cfb6e4e52c0d3d73c8da32de1834f036$ && posted: ^返事を待つ役:.*mention://agent/agent-codex-principal`
2. [記録] 設計の役へ進めず、古い値での再依頼もしない。 `判定: not-posted: mention://agent/agent-designer && not-posted: ^確認するコミット: タスクの本文 577d6f78b89ebafedb1696a3b231c34128de694aa37df80cff132662b1373ca9$ && not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
