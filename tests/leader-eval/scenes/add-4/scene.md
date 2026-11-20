- 場面の ID: add-4
- 型: 新

## 元の出来事

要件を決める役がある構成では、新しい要望をその役へ回す流れを保つことを確認する。要件の見直しは頼まない。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` の人間のコメント `comment-2` で起きました。返信は `--parent comment-2` を使います。コメントは「カートのアイコンに商品数を出したい。要件から進めてください」です。タスクは `in_progress` で、要件はまだ合意していません。PR はありません。

## 合格の基準

1. [記録] 要件を決める役へ回す。 `判定: posted: mention://agent/agent-planner && not-posted: mention://agent/agent-designer`
2. [記録] 最上位の役に要件の見直しを頼まない。 `判定: not-called: ^squad-review-wait watch && not-posted: mention://agent/agent-codex-principal && not-posted: mention://agent/agent-claude-principal && not-posted: ^見直しの種類: 要件の見直し$`
