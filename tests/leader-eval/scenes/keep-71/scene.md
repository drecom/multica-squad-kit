- 場面の ID: keep-71
- 型: 保

## 元の出来事

設計の役が差を表に載せて返したとき、リーダーは設計の承認を求めず、止めていたレビューを頼む。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` の設計の役のコメント `c-handling` で起きました。返信は `--parent c-handling` を使います。先に実装の役が設計との差を返し、リーダーが設計の役へ回しました。設計の役は変更の一覧だけを直して push し、`設計との差の扱い: src/cart/Badge.css 表に載せる` の行と、止めていたレビューを頼むよう返しました。設計の決めたことは変わっていません。全フェーズは実装済みで、レビューの依頼はまだありません。 PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。タスクは `in_progress` です。

## 合格の基準

1. [記録] 今の head で、止めていたレビューを頼んでいる。 `判定: called: ^squad-review-next request issue-shop-1 c-handling 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567$`
2. [記録] 設計の変更の行を置かず、ラベルも付けず、設計の役へ頼み直していない。 `判定: not-posted: ^設計の変更: && not-posted: mention://agent/agent-designer && not-called: ^multica issue label add`
3. [記録] 人間を呼ばず、in_review にしていない。 `判定: not-posted: mention://member/member1 && not-called: ^multica issue status issue-shop-1 in_review`
4. [採点] 表への追記を設計の決めたことの変更と扱わず、設計の承認を挟んでいない。
