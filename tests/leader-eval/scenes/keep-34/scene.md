- 場面の ID: keep-34
- 型: 保

## 元の出来事

種類単位で頼んだ修正が返ったとき、`squad-review-next request` で再確認を頼む。列挙を頼む部品の行は request が書く。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-fix2` で起きました。返信は `--parent c-fix2` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、`重要` のラベルやマークはありません。タスクは `in_progress` です。修正の役が、種類単位で頼んだ `src/cart/Badge.tsx:formatCount` の直し（`c-req2`、`頼む範囲: 種類単位` の行あり）を push したと返しました（コメント `c-fix2`）。入力の種類の表をテストに沿わせたと書かれています。直したコミットは `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` で、レビューを頼み直す番です。

## 合格の基準

1. [記録] request で、直したコミットの再確認を頼んでいる。 `判定: called: ^squad-review-next request issue-shop-1 c-fix2 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567$`
2. [記録] 人間を呼ばず、修正の役へ回し直していない。手で watch せず、列挙の行も自分で書いていない。 `判定: not-posted: mention://member/member1 && not-posted: mention://agent/agent-claude-fixer && not-called: ^multica issue status .* in_review && not-called: ^squad-review-wait watch && not-posted: ^列挙を頼む部品:`
