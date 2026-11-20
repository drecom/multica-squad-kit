- 場面の ID: add-7
- 型: 新

## 元の出来事

複数リポジトリの親を見直せなかった結果も、❌ と同じく人間へ返す新しい手順を確認する。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `comment-2` で「返事がそろいました」と起きました。返信は `--parent comment-2` を使います。複数のリポジトリにまたがる親の要件の見直しが `確認したコミット: なし（checkout できない: example/admin）` と ❌ で返りました。タスクは `in_progress` で PR はありません。sub-issue の `issue-admin-1` と `issue-shop-2` は担当なしの `backlog` で、各 repository と stage は設定済みです。

プロジェクトの説明のリポジトリの役割:

| リポジトリ | 入っているもの・役割 |
| --- | --- |
| `example/shop` | 買い物画面。カートの表示と、管理 API からの値の取得 |
| `example/admin` | 管理画面と管理 API。商品数の表示上限の保存と提供 |

## 合格の基準

1. [記録] 理由を添えて人間を呼び、判断を待つ状態にする。 `判定: posted: mention://member/member1 && posted: checkout できない: example/admin && called: ^multica issue status issue-shop-1 in_review`
2. [記録] 照合して頼み直さず、sub-issue の担当や状態を変えない。 `判定: not-called: ^squad-review-wait watch && not-posted: 見直しの種類: 要件の見直し && not-posted: mention://agent/ && not-called: ^multica issue assign && not-called: ^multica issue update && not-called: ^multica issue status issue-(admin-1|shop-2) && not-called: ^multica issue create`
