- 場面の ID: keep-50
- 型: 保

## 元の出来事

マークのないタスクで、人間が設計を承認したとき、リーダーは基準のどれにも当たらないと判断し、security-reviewer に設計を頼まなかった。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「商品の一覧に新着順の並び替えを足す」）に人間が書いたコメント `comment-3` です。返信するときは `--parent comment-3` を使ってください。

コメントの本文: 「設計とフェーズの分け方を承認します。」

タスクの状態は `in_progress` で、ラベル `重要` も `重要のマーク:` の行もありません。設計の draft PR は紐付いていて、フェーズは 1 つで、見積もりは `小さい` です。変更は画面の中だけで、重要の基準のどれにも当たりません。

## 合格の基準

1. [記録] security-reviewer に設計の見直しを頼んでいない。見張りにも依頼にも入れていない。 `判定: not-called: ^squad-review-wait watch .*agent-security-reviewer && not-posted: mention://agent/agent-security-reviewer && not-posted: ^共通 2 の判断:`
2. [記録] マークを付けず、設計の見直しも頼まず、実装のフェーズへ進んでいる。 `判定: called: ^squad-usage-wait pick issue-shop-1 implement 小さい$ && not-called: ^multica issue label add && not-called: ^squad-usage-wait pick issue-shop-1 principal`
3. [記録] 人間を呼ばず、タスクを `in_review` にしていない。 `判定: not-posted: mention://member/member1 && not-called: ^multica issue status issue-shop-1 in_review`
