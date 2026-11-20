- 場面の ID: add-25
- 型: 新
- 外す役: designer

## 元の出来事

設計の役を置かない構成で、設計と PR の見直しの `設計` の指摘を人間が直して承認し直したとき、止めた振り分けを再開し、`コード` の指摘を修正の依頼に添える手順を確認する。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）に人間が書いたコメント `c-11`（本文: 「設計を直して push した。設計とフェーズを承認し直します。」）です。返信するときは `--parent c-11` を使ってください。

設計の役は外されています。タスクの状態は `in_review` で、過去に共通 4 でマークが付いたタスクです。ラベル `重要` が付いていて、`重要のマーク:` の行に共通 4 があります。修正の依頼は `c-3`〜`c-5` の 3 回で、4 回目になる `c-6` のコードレビューの役の ❌ への依頼は、そのマークのために止めてあります。`c-7` で最上位の役に設計と PR の見直しを頼み、結果（`c-8`）は ❌（設計 1 件、コード 1 件: `src/cart/Badge.test.tsx` に境界の 99 と 100 のテストがない）でした。`c-10` で、リーダーが人間に設計の直しと承認し直しを頼んでいます。

PR の head は `8d4e1b7a9c2f5036b1e8d7a4c3f2e1d0b9a87654` です。人間が設計を直して push したあとの head で、承認し直しの返事は `c-11` です。

## 合格の基準

1. [記録] 承認の返事を受けてタスクを `in_progress` に戻し、修正の役を選び、止めた修正の依頼（`c-6`）に `コード` の指摘（`c-8`）を加えて、4 回目として頼んでいる。 `判定: called: ^multica issue status issue-shop-1 in_progress && called: ^squad-usage-wait pick issue-shop-1 fix && posted: (?sm)\A(?=.*mention://agent/agent-claude-fixer)(?=.*^修正の依頼: 4 回目$)(?=.*^数え直し: 同じ誤りのすべて。理由: 設計の承認し直し$)`
2. [記録] 最上位の役に直した設計を見せ直さず、設計の役と人間を呼ばず、タスクを `in_review` にしていない。 `判定: not-posted: mention://agent/agent-(claude|codex)-principal && not-posted: mention://agent/agent-designer && not-posted: mention://member/member1 && not-posted: ^見せ直し: && not-called: ^squad-review-wait watch && not-called: ^multica issue status issue-shop-1 in_review`
3. [採点] 修正の依頼に、止めた依頼の指摘（`c-6`）と、最上位の役の `コード` の指摘（`c-8`）の両方を入れている。`設計` の指摘を修正の依頼に入れていない。
