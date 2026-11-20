- 場面の ID: keep-70
- 型: 保

## 元の出来事

実装の役が一覧にない変更を設計との差の行で返したとき、リーダーはレビューの前に設計の役へ回す。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` の実装の役のコメント `c-impl-diff` で起きました。返信は `--parent c-impl-diff` を使います。コメントには `設計との差: src/cart/Badge.css 余白の追加が変更の一覧にない` の行があります。設計と全フェーズは承認・実装済みで、単体テストも成功しています。 PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。タスクは `in_progress` です。

## 合格の基準

1. [記録] 設計の役を選び、差の行をそのまま写して設計の役へ頼んでいる。 `判定: called: ^squad-usage-wait pick issue-shop-1 designer && posted: mention://agent/agent-designer && posted: ^設計との差: src/cart/Badge\.css 余白の追加が変更の一覧にない$`
2. [記録] レビューと最終レビューを頼まず、設計の変更の行も置いていない。 `判定: not-called: ^squad-review-next request && not-called: ^squad-review-wait watch && not-posted: mention://agent/agent-(code-reviewer|ux-reviewer|security-reviewer|performance-reviewer|qa|claude-principal|codex-principal) && not-posted: ^設計の変更:`
3. [記録] 人間を呼ばず、in_review にしていない。 `判定: not-posted: mention://member/member1 && not-called: ^multica issue status issue-shop-1 in_review`
4. [採点] 依頼が、差の扱いを設計の役に決めてもらう内容になっている。設計を変えることを先に決めていない。
