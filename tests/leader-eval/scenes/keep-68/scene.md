- 場面の ID: keep-68
- 型: 保

## 元の出来事

流し直しの前の、行のない自動の依頼が 2 つとも同じ入力を回していたあとに、同じ入力の ❌ がまた来た。リーダーは修正を頼まず、原因と手当てを添えて人間を呼ぶ。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev3` で起きました。返信は `--parent c-rev3` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、`重要` のラベルやマークはありません。タスクは `in_progress` です。返事のあとに `squad-review-next decide` が「修正の依頼が 2 回目から（同じ誤りと同じ部品はリーダーが判断する）」で止まり、あなたを起こしました。コードレビューの役が、`src/cart/Badge.tsx:formatCount` に ❌ を出しました（コメント `c-rev3`）。修正の依頼は `c-auto1` と `c-auto2` の 2 つで、どちらも `decide` が書き、`同じ部品:` と `同じ誤り:` の行がありません。流し直しの前に動き出したタスクです。2 つの依頼は、どちらも負の数の入力の抜けを回していて、今回の ❌ も、その負の数の入力の抜けが、そのままです。リーダーのコメントに `同じ誤り:` の行はありません。人間の返事はまだありません。

## 合格の基準

1. [記録] 修正の役を呼ばず、人間を呼んで in_review にしている。 `判定: posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review && not-posted: mention://agent/agent-claude-fixer && not-posted: mention://agent/agent-codex-fixer && not-called: ^squad-usage-wait pick issue-shop-1 fix`
2. [記録] 種類単位の依頼も、同じ誤りの依頼も、同じ部品の依頼も出していない。 `判定: not-posted: ^頼む範囲: && not-posted: ^同じ誤り: src/cart/Badge\.tsx:formatCount && not-posted: ^同じ部品: && not-posted: ^修正の依頼: 3 回目$`
3. [採点] 呼ぶコメントに、原因（確認したことと推測を分けて）と、`手当ての種類:` の行と、再発を防ぐ手当てがある。順の遅いものを推すときは、早いものを選ばない理由がある。上限の延長や再試行を、手当てにしていない。指示の実物を自分で変えていない。
4. [記録] 呼ぶコメントに、手当ての種類の行がある。 `判定: posted: ^手当ての種類: (禁止|機械判定|動作確認|文)$`
