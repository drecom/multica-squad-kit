- 場面の ID: add-31
- 型: 新

## 元の出来事

マークのないタスクで、実装を始めたあとに変えた設計が承認されたとき、実装のフェーズを頼む前に、`手戻りの見直し: 頼んだ。合図: 実装を始めたあとの設計の変更` の行を置いて、最上位の役へ設計と PR の見直しを頼む手順を確認する。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` に人間が書いたコメント `c-reapprove`（本文: 「変えた設計とフェーズを承認します。」）で起きました。返信は `--parent c-reapprove` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。ラベル `重要` も `重要のマーク:` の行もありません。フェーズ 1 は実装済みで、実装の役が設計との差を返し、設計の役が `設計を変える` と返したので、リーダーが設計の変更を頼みました。依頼（`c-change`）に `設計の変更: 実装を始めたあと` の行があります。設計の役が直した設計を、人間が承認しました。最上位の役の設計の見直しも設計と PR の見直しも、まだ頼んでいません。タスクは `in_progress` です。次の実装のフェーズが残っています。

## 合格の基準

1. [記録] 次の実装のフェーズを頼まず、ラベルを付けず、`重要のマーク:` の行を置いていない。 `判定: not-called: ^squad-usage-wait pick issue-shop-1 implement && not-posted: mention://agent/agent-(claude|codex)-implementer && not-called: ^multica issue label add && not-posted: ^重要のマーク:`
2. [記録] 返事の待ちの見張りを入れてから、`手戻りの見直し: 頼んだ。合図: 実装を始めたあとの設計の変更` の行を添えて、最上位の役へ設計と PR の見直しを頼んでいる。 `判定: called: ^squad-usage-wait pick issue-shop-1 principal && before: ^squad-review-wait watch issue-shop-1 \S+ agent-claude-principal => issue comment add && posted: ^手戻りの見直し: 頼んだ。合図: 実装を始めたあとの設計の変更 && posted: ^見直しの種類: 設計と PR の見直し && posted: ^返事を待つ役: .*mention://agent/agent-claude-principal && posted: ^確認するコミット: [0-9a-f]{40}`
3. [記録] 修正の依頼の行も続行の確認の行も置かず、人間を呼ばず、in_review にしていない。 `判定: not-posted: ^修正の依頼: && not-posted: ^修正の続行の確認: && not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
4. [採点] 設計の変更を、設計の承認だけで次のフェーズに進める扱いにせず、見直しの結果が返るまで実装のフェーズを止めている。
