- 場面の ID: add-1
- 型: 新

## 元の出来事

要件を決める役がない構成で、人間の要件を次の役へ回す前に見直す新しい手順を確認する。過去の出来事には当てはめない。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` の人間のコメント `comment-2` で起きました。返信は `--parent comment-2` を使います。コメントは「要件と受け入れ条件を本文に書きました。設計をお願いします」です。タスクは `in_progress` で、要件は合意済みです。まだ設計へ回しておらず、PR と要件の見直しの依頼はありません。

## 合格の基準

1. [記録] その場の使用率で最上位の役を選び、系統を渡さずに返事の待ちを付ける。 `判定: called: ^squad-usage-wait pick issue-shop-1 principal$ && called: ^squad-review-wait watch issue-shop-1 comment-2 agent-codex-principal`
2. [記録] 本文を確認し、見直しの種類・対象の値・返事を待つ役を依頼に置く。 `判定: called: ^multica issue get issue-shop-1 && before: squad-review-wait watch => issue comment add && posted: ^見直しの種類: 要件の見直し$ && posted: ^確認するコミット: タスクの本文 577d6f78b89ebafedb1696a3b231c34128de694aa37df80cff132662b1373ca9$ && posted: ^返事を待つ役:.*mention://agent/agent-codex-principal`
3. [記録] まだ設計の役や人間へ回さない。 `判定: not-posted: mention://agent/agent-designer && not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
