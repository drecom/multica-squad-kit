- 場面の ID: add-9
- 型: 新
- 外す役: designer

## 元の出来事

設計の役を置かない構成では、人間が用意した設計を最上位の役が見直す新しい手順を確認する。成功の条件と確認方法のそろい方も見直し、人間が結果を読んで承認してから実装へ回す。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）に、人間が設計の PR とフェーズの一覧を用意したコメント `comment-2` を置きました。返信は `--parent comment-2` を使います。

設計の役は外されています。要件は合意済みで、タスクにラベル `重要` はありません。PR は紐付いており、タスクは `in_progress` です。CLI 見本の `squad-usage-wait pick issue-shop-1 principal` は、最上位の役を選んで終了 0 を返します。

## 合格の基準

1. [記録] 使用率から最上位の役を選んでいる。 `判定: called: ^squad-usage-wait pick issue-shop-1 principal$`
2. [記録] 依頼を書く前に返事の待ちを入れる。 `判定: called: ^squad-review-wait watch issue-shop-1 comment-2 agent-claude-principal && before: ^squad-review-wait watch => issue comment add`
3. [記録] 最上位の役に、人間の設計の見直しを、同じコミットで頼んでいる。 `判定: posted: mention://agent/agent-claude-principal && posted: ^見直しの種類: 設計の見直し$ && posted: ^設計を用意した人: 人間$ && posted: ^返事を待つ役: .*mention://agent/agent-claude-principal && posted: ^確認するコミット: 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567$`
4. [記録] 実装を頼まず、見直しの前に人間の承認も頼まない。 `判定: not-posted: mention://agent/agent-(claude|codex)-implementer && not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
5. [採点] 受け入れ条件ごとに成功の条件と確認方法がそろっているかを見るよう、最上位の役に頼んでいる。
6. [採点] 最上位の役の見直しのあとに、結果を人間に示して設計とフェーズの承認を頼むと書いている。
