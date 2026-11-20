- 場面の ID: add-38
- 型: 新

## 元の出来事

見直しを受けたマークのないタスクで、修正が返ったとき、ラベルも観点をすべてにする指定も足さず、`squad-review-next request` でレビューを頼む手順を確認する。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-fix4` で起きました。返信は `--parent c-fix4` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みです。ラベル `重要` も `重要のマーク:` の行もありません。リーダーが `手戻りの見直し: 頼んだ。合図: 修正の依頼が 4 回目` の行を置いて（`c-ask4`）最上位の役に設計と PR の見直しを頼み、結果（`c-prin`）は ✅ で指摘なしでした。そのあと `src/cart/store.ts:addItem` の直しを `修正の依頼: 4 回目`（`c-req4`）で頼みました。タスクは `in_progress` です。修正の役が、直して push したと返しました（コメント `c-fix4`）。直したコミットは `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` で、レビューを頼み直す番です。

## 合格の基準

1. [記録] request で、直したコミットの再確認を頼んでいる。引数に観点を足していない。 `判定: called: ^squad-review-next request issue-shop-1 c-fix4 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567$`
2. [記録] ラベルを付けず、`重要のマーク:` の行も `手戻りの見直し:` の行も置いていない。人間を呼ばず、修正の役へ回し直さず、最上位の役を呼ばず、手で watch せず、列挙の行も自分で書いていない。 `判定: not-called: ^multica issue label add && not-posted: ^重要のマーク: && not-posted: ^手戻りの見直し: && not-posted: mention://member/member1 && not-posted: mention://agent/agent-claude-fixer && not-called: ^squad-usage-wait pick issue-shop-1 principal && not-posted: mention://agent/agent-(claude|codex)-principal && not-called: ^multica issue status .* in_review && not-called: ^squad-review-wait watch && not-posted: ^列挙を頼む部品:`
3. [採点] 見直しを受けたことを理由に、レビューの観点をすべて頼む扱いにしていない。観点は request が変えたファイルで選ぶ。
