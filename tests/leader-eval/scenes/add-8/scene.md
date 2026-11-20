- 場面の ID: add-8
- 型: 新

## 元の出来事

一覧に 2 つのリポジトリがあっても、本文が 1 つの役割だけに当たる場合は、単一のリポジトリのタスクとして扱う境界を確認する。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` の人間のコメント `comment-2` で起きました。返信は `--parent comment-2` を使います。コメントは「要件と受け入れ条件を本文に書きました。設計をお願いします」です。本文の要件は、買い物画面のカートのアイコンに商品の数を出すことだけで、管理画面や管理 API の変更はありません。タスクは `in_progress`、要件は合意済みで PR と sub-issue はありません。metadata の `repository` はまだありません。

プロジェクトの説明のリポジトリの役割:

| リポジトリ | 入っているもの・役割 |
| --- | --- |
| `example/shop` | 買い物画面。カートの表示と、管理 API からの値の取得 |
| `example/admin` | 管理画面と管理 API。商品数の表示上限の保存と提供 |

## 合格の基準

1. [記録] タスク自身の作業先を買い物画面に決め、先に記録する。 `判定: called: ^multica issue metadata set issue-shop-1 .*--key repository .*--value example/shop && before: ^multica issue metadata set => ^squad-review-wait watch`
2. [記録] 親の本文の値で見直しを頼む。 `判定: called: ^squad-review-wait watch issue-shop-1 comment-2 agent-codex-principal && before: ^squad-review-wait watch => ^multica issue comment add && posted: ^見直しの種類: 要件の見直し$ && posted: ^確認するコミット: タスクの本文 577d6f78b89ebafedb1696a3b231c34128de694aa37df80cff132662b1373ca9$ && posted: ^返事を待つ役:.*mention://agent/agent-codex-principal`
3. [記録] sub-issue を作らず、人間も呼ばない。 `判定: not-called: ^multica issue create && not-posted: mention://member/member1 && not-posted: mention://agent/agent-designer && not-called: ^multica issue status .* in_review`
4. [採点] リポジトリが 2 つあることだけで分割せず、本文が買い物画面の役割だけに当たることから、単一リポジトリのタスクとして扱っている。
