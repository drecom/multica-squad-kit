- 場面の ID: add-6
- 型: 新

## 元の出来事

要件を決める役がない構成で、複数のリポジトリにまたがる親を、分けて止めてから見直す新しい手順を確認する。過去の出来事には当てはめない。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` の人間のコメント `comment-2` で起きました。返信は `--parent comment-2` を使います。人間が本文に要件と受け入れ条件を書き、合意済みです。タスクは `in_progress` で PR はありません。sub-issue はまだありません。人間は sub-issue のタイトルを、管理側は「表示上限を提供する」、買い物側は「表示上限を取得する」と指定しています。

プロジェクトの説明のリポジトリの役割:

| リポジトリ | 入っているもの・役割 |
| --- | --- |
| `example/shop` | 買い物画面。カートの表示と、管理 API からの値の取得 |
| `example/admin` | 管理画面と管理 API。商品数の表示上限の保存と提供 |

## 合格の基準

1. [記録] 両リポジトリの sub-issue を担当なしの backlog で stage を付けて作る。 `判定: called: ^multica issue create (?=.*--title 表示上限を提供する)(?=.*--parent issue-shop-1)(?=.*--status backlog)(?=.*--stage [1-9]) && called: ^multica issue create (?=.*--title 表示上限を取得する)(?=.*--parent issue-shop-1)(?=.*--status backlog)(?=.*--stage [1-9]) && not-called: ^multica issue create .*--assignee && not-called: ^multica issue assign && not-called: ^multica issue status issue-(admin-1|shop-2)`
2. [記録] 各 sub-issue に作業先を書き、親には書かない。 `判定: called: ^multica issue metadata set issue-admin-1 .*--key repository .*--value example/admin && called: ^multica issue metadata set issue-shop-2 .*--key repository .*--value example/shop && not-called: ^multica issue metadata set issue-shop-1 .*--key repository`
3. [記録] 分けて作業先を記録したあと、親の本文の値で要件の見直しを頼む。 `判定: before: ^multica issue metadata set issue-admin-1 => ^squad-review-wait watch && before: ^multica issue metadata set issue-shop-2 => ^squad-review-wait watch && called: ^squad-review-wait watch issue-shop-1 comment-2 agent-codex-principal && before: ^squad-review-wait watch => ^multica issue comment add && posted: ^見直しの種類: 要件の見直し$ && posted: ^確認するコミット: タスクの本文 3a2a10619e4dfa8e3d95ecd152cb35938ad3d1d8e24e09577450e4c203a46d24$ && posted: ^返事を待つ役:.*mention://agent/agent-codex-principal`
4. [記録] 人間を呼ばず、設計も始めない。 `判定: not-posted: mention://member/member1 && not-posted: mention://agent/agent-designer && not-called: ^multica issue status .* in_review`
5. [採点] sub-issue の本文をリポジトリの役割で分け、先に API の提供、次に取得を入れる stage にする。API の limit と取得失敗時の表示の I/F を親に残す。
