- 場面の ID: add-26
- 型: 新
- 外す役: designer

## 元の出来事

設計の役を置かない構成で、診断が `直す役: 設計の役` を返したとき、人間に設計の変更と承認し直しを頼み、`設計の変更: 実装を始めたあと` の行を置く手順を確認する。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）で、最上位の役が書いたコメント `comment-6` です。返信するときは `--parent comment-6` を使ってください。

コメントの本文は次のとおりです。`squad-review-wait report` が、全員の返事がそろったときに書く知らせです。

```text
返事がそろいました。
次の依頼を決められません: 診断の回はリーダーが扱う
```

設計の役は外されています。タスクの状態は `in_progress` で、ラベル `重要` はありません。実装は push 済みで、`comment-2` の修正の依頼のあとも CI の同じテストが失敗したので、`comment-4` で最上位の役に診断を頼みました。診断（`comment-5`）は `直す役: 設計の役` です。`squad-review-wait proceed` は `返事の待ち: 次に進む` を返します。

## 合格の基準

1. [記録] 返事を受けて次に進んでから、人間をメンションし、診断（`comment-5`）へのリンクを添えて、設計の変更と承認し直しを頼み、`設計の変更: 実装を始めたあと` の行を置き、タスクを `in_review` にしている。 `判定: before: ^squad-review-wait proceed issue-shop-1 comment-6 => issue comment add && posted: mention://member/member1 && posted: comment-5 && posted: 承認し直 && posted: ^設計の変更: 実装を始めたあと$ && called: ^multica issue status issue-shop-1 in_review`
2. [記録] 設計の役、実装の役、修正の役を呼ばず、修正の依頼も数え直しの行も書いていない。 `判定: not-posted: mention://agent/agent-(designer|claude-implementer|codex-implementer|claude-fixer|codex-fixer) && not-posted: ^修正の依頼: && not-posted: ^数え直し: && not-posted: ^診断の数え直し: && not-called: ^squad-usage-wait pick && not-called: ^squad-review-wait watch`
3. [採点] 依頼に、診断の内容（設計の表示の仕様が 2 通りに読めること）と直し方（`100 以上は 99+` に 1 つへ決める）を添えている。
