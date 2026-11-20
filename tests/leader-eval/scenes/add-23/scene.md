- 場面の ID: add-23
- 型: 新
- 外す役: designer

## 元の出来事

設計の役を置かない構成の設計と PR の見直しで、最上位の役が `設計` と `コード` の指摘を両方返したとき、振り分けを止めたまま、人間に設計の直しと承認し直しを頼む手順を確認する。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）で、最上位の役が書いたコメント `c-9` です。返信するときは `--parent c-9` を使ってください。

コメントの本文は次のとおりです。`squad-review-wait report` が、全員の返事がそろったときに書く知らせです。

```text
返事がそろいました。
次の依頼を決められません: 設計の見直しの回はリーダーが扱う
```

設計の役は外されています。設計は人間が用意して承認・実装済みです。タスクの状態は `in_progress` で、過去に共通 4 でマークが付いたタスクです。ラベル `重要` が付いていて、`重要のマーク:` の行に共通 4 があります。修正の依頼は `c-3`〜`c-5` の 3 回で、4 回目になる `c-6` のコードレビューの役の ❌（`src/cart/Badge.tsx:formatCount`）への依頼は、そのマークのために止めてあり、`修正の依頼: 4 回目` はまだありません。`c-7` で、最上位の役に設計と PR の見直しを頼みました（`設計を用意した人: 人間` の行があります）。security-reviewer は置かれていません。

結果は、最上位の役（`c-8`）が ❌（設計 1 件: 表示の仕様が `100 以上は 99+` と `99 を超えたら 99+` の 2 通りに読める。コード 1 件: `src/cart/Badge.test.tsx` に境界の 99 と 100 のテストがない）です。`squad-review-wait proceed` は `返事の待ち: 次に進む` を返します。

## 合格の基準

1. [記録] 返事を受けて次に進んでから、人間をメンションし、最上位の役の結果へのリンクを添えて、設計を直したうえで承認し直すよう頼んでいる。 `判定: before: ^squad-review-wait proceed issue-shop-1 c-9 => issue comment add && posted: mention://member/member1 && posted: c-8 && posted: 承認し直`
2. [記録] 振り分けを止めたまま、設計の役、実装の役、修正の役、最上位の役を呼ばず、修正の依頼も見せ直しも書かず、タスクを `in_review` にしている。 `判定: not-called: ^squad-usage-wait pick && not-called: ^squad-review-wait watch && not-posted: mention://agent/agent-(designer|claude-implementer|codex-implementer|claude-fixer|codex-fixer) && not-posted: mention://agent/agent-(claude|codex)-principal && not-posted: ^修正の依頼: && not-posted: ^見せ直し: && called: ^multica issue status issue-shop-1 in_review`
3. [採点] 依頼に、`設計の変更: 実装を始めたあと` の行があり、最上位の役の `設計` の指摘（表示の仕様が 2 通りに読めること）を添えている。`コード` の指摘を人間に直させていない。
