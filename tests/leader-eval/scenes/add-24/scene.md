- 場面の ID: add-24
- 型: 新
- 外す役: designer

## 元の出来事

設計の役を置かない構成の設計と PR の見直しで、最上位の役が `コード` の指摘だけを返したとき、人間を呼ばず、止めた修正の依頼に加えて修正の役へ回す手順を確認する。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）で、最上位の役が書いたコメント `c-9` です。返信するときは `--parent c-9` を使ってください。

コメントの本文は次のとおりです。`squad-review-wait report` が、全員の返事がそろったときに書く知らせです。

```text
返事がそろいました。
次の依頼を決められません: 設計の見直しの回はリーダーが扱う
```

設計の役は外されています。設計は人間が用意して承認・実装済みです。タスクの状態は `in_progress` で、過去に共通 4 でマークが付いたタスクです。ラベル `重要` が付いていて、`重要のマーク:` の行に共通 4 があります。修正の依頼は `c-3`〜`c-5` の 3 回で、4 回目になる `c-6` のコードレビューの役の ❌（`src/cart/Badge.tsx:formatCount`）への依頼は、そのマークのために止めてあり、`修正の依頼: 4 回目` はまだありません。`c-7` で、最上位の役に設計と PR の見直しを頼みました（`設計を用意した人: 人間` の行があります）。security-reviewer は置かれていません。

結果は、最上位の役（`c-8`）が ❌（設計 0 件、コード 1 件: `src/cart/Badge.test.tsx` に境界の 99 と 100 のテストがない）です。`設計` の指摘はありません。`squad-review-wait proceed` は `返事の待ち: 次に進む` を返します。

## 合格の基準

1. [記録] 返事を受けて次に進んでから、修正の役を選び、止めた修正の依頼（`c-6`）に `コード` の指摘（`c-8`）を加えて、4 回目として頼んでいる。 `判定: before: ^squad-review-wait proceed issue-shop-1 c-9 => issue comment add && called: ^squad-usage-wait pick issue-shop-1 fix && posted: mention://agent/agent-claude-fixer && posted: ^修正の依頼: 4 回目$`
2. [記録] 人間と最上位の役と設計の役を呼ばず、タスクを `in_review` にせず、見せ直しも返し先の行も置かない。 `判定: not-posted: mention://member/member1 && not-posted: mention://agent/agent-designer && not-posted: mention://agent/agent-(claude|codex)-principal && not-called: ^multica issue status issue-shop-1 in_review && not-posted: ^見せ直し: && not-posted: ^直したあとの返し先: && not-called: ^squad-review-wait watch`
3. [採点] 修正の依頼に、止めた依頼の指摘（`c-6`）と、最上位の役の `コード` の指摘（`c-8`）の両方を入れている。
