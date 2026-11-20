- 場面の ID: add-2
- 型: 新

## 元の出来事

要件の見直しに指摘がなければ、人間を呼ばずに次の役へ回す新しい手順を確認する。本文は見直しの前後で同じである。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `comment-2` で「返事がそろいました」と起きました。返信は `--parent comment-2` を使います。要件の見直しの回です。最上位の役から ✅ と「設計への指摘: なし」が返りました。依頼と結果は同じ本文の値です。本文は依頼のあとも変わっていません。タスクは `in_progress` で、PR はありません。

## 合格の基準

1. [記録] 今の本文を確認し、人間を呼ばず設計の役へ回す。 `判定: called: ^multica issue get issue-shop-1 && posted: mention://agent/agent-designer && not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
2. [記録] 要件の見直しを頼み直さない。 `判定: not-called: ^squad-review-wait watch && not-posted: ^見直しの種類: 要件の見直し$`
