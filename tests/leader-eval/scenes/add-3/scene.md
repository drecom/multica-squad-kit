- 場面の ID: add-3
- 型: 新

## 元の出来事

要件の見直しに指摘があれば、人間に要件の直しを頼む新しい手順を確認する。設計へはまだ回さない。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `comment-2` で「返事がそろいました」と起きました。返信は `--parent comment-2` を使います。要件の見直しの回です。最上位の役から ⚠️ が返り、指摘は「空のカートの表示が決まっていません。空のときの表示を決めてください」です。タスクは `in_progress` で、PR はありません。

## 合格の基準

1. [記録] 人間を呼び、判断を待つ状態にする。 `判定: posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review && not-posted: mention://agent/agent-designer`
2. [採点] 空のカートの表示が決まっていないという指摘を添えて、人間に要件の直しを頼む。
