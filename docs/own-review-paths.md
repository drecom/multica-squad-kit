# このリポジトリのレビューの観点の対応

この文書は、原本を変える人に向けて、このリポジトリの根に置く `.agents/review-paths` の行と、その行を選んだ理由を決める。対応の書き方と、上書き・追加の決まりは [review-next-step.md の観点の選び方](review-next-step.md#観点の選び方)を正本とし、この文書には写さない。

## 目的と範囲

目的は、このリポジトリの重要のマークのない PR で、変えたファイルに合う観点だけを頼むことである。今は対応のファイルがなく、原本の既定の対応に当たらないファイルが 34 件ある。そのどれかを変えた PR は、すべての観点を頼む。

既定に当たらないファイルには、`MANIFEST` が入る。`MANIFEST` は、どのファイルを変えても `bash scripts/manifest.sh` で作り直して積むので、ほぼすべての PR が変える。このため、文書だけを変えた PR でも、すべての観点を頼んでいる。

この文書で決めるのは、次の 3 つである。

1. 対応のファイルの置き場所と全文。[ファイルの置き場所](#ファイルの置き場所)と[ファイルの全文](#ファイルの全文)に書く
2. 行ごとの理由。[行を選んだ理由](#行を選んだ理由)に書く
3. 対応を保つテスト。[テスト](#テスト)に書く

次は、この文書の範囲の外である。

- 原本の既定の対応（`squad-review-next` の中の対応）と、プロジェクトのひな形（`skeleton/.agents/review-paths`）の変更
- 名簿から役を外すこと
- 重要のマークの付け方。役の判断や手順を変える変更は、今の重要の基準のとおりマークが付き、すべての観点を頼む

## ファイルの置き場所

対応のファイルは、このリポジトリの根の `.agents/review-paths` に 1 つだけ置く。`squad-review-next` が読むのはこの場所だけで、ほかの場所に置いても読まれないためである。

このファイルは、このリポジトリのための設定で、導入先のリポジトリには置かれない。セットアップは、原本の根の `.agents/` を導入先のリポジトリへ写さない。今の `.agents/rules/` と同じ扱いである。`bash scripts/manifest.sh` は、`.git` と `tmp` のほかのすべてのファイルを `MANIFEST` に載せるので、このファイルも `MANIFEST` に載る。

## ファイルの全文

対応のファイルは、次の全文にする。理由の文はこの文書に置き、ファイルのコメントは行のまとまりの見出しにとどめる。

```text
# このリポジトリの観点の対応。原本の既定の対応に当たらない場所を足し、スクリプトの観点を足す。
# 書き方と、上書き・追加の決まりは docs/review-next-step.md の「観点の選び方」にある。
# 行を選んだ理由は docs/own-review-paths.md にある。

# 生成物・バージョンの番号・設定とデータ。中身の誤りはコードのレビューで見る
MANIFEST code-reviewer
VERSION code-reviewer
.gitattributes code-reviewer
.gitignore code-reviewer
.markdownlint.json code-reviewer
common/labels code-reviewer
common/setup-issues.json code-reviewer
common/agents/FORMAT code-reviewer
scripts/metrics-plan.json code-reviewer
scripts/style-exempt.txt code-reviewer
skeleton/.agents/review-paths code-reviewer

# 依存の更新の設定と、この対応のファイル。外から入るものと、頼む観点を決めるので、セキュリティも頼む
.github/dependabot.yml code-reviewer,security-reviewer
.agents/review-paths code-reviewer,security-reviewer

# 役やホストが実行するスクリプトと設定。権限に関わるので、セキュリティも頼む
common/guard/ code-reviewer,security-reviewer
common/shell/ code-reviewer,security-reviewer
common/codex/ code-reviewer,security-reviewer

# 起動と見張りのスクリプト。待ち時間にも関わるので、性能も頼む
common/host/ code-reviewer,security-reviewer,performance-reviewer
common/monitor/ code-reviewer,security-reviewer,performance-reviewer
vm/ code-reviewer,security-reviewer,performance-reviewer

# セットアップのスクリプト。登録と認証に関わるので、セキュリティも頼む
setup.sh code-reviewer,security-reviewer
install.sh code-reviewer,security-reviewer
lib/ code-reviewer,security-reviewer
```

`/` を含む型はリポジトリの根から当たるので、`.agents/review-paths` の行はひな形の `skeleton/.agents/review-paths` に当たらない。`/` を含まない型（`MANIFEST`・`VERSION`・`setup.sh` など）はどの深さのファイル名にも当たるが、設計の時点で同じ名前のファイルはほかの場所にない。

## 行を選んだ理由

行は、既定に当たらない場所を足す行と、既定より観点を足す行の 2 種類である。どちらも、プロジェクトの行に当たったファイルは、既定の行を使わず、その行の役だけを使う（上書き）。

| 行のまとまり | 当たるファイル | 頼む観点 | 理由 |
| --- | --- | --- | --- |
| 生成物・バージョンの番号・設定とデータ | `MANIFEST`・`VERSION`・根の設定・ラベルと起票の一覧・役の形式・開発用の JSON と一覧・ひな形の対応 | コード | どれも既定に当たらない。中身の誤り（ハッシュの食い違い・バージョンの形・一覧の漏れ）は、テストとコードのレビューで見つかる |
| 依存の更新の設定 | `.github/dependabot.yml` | コード、セキュリティ | 外から入る依存を決める。既定の配布と依存の行（`.github/workflows/` など）と同じ観点にそろえる |
| この対応のファイル | `.agents/review-paths` | コード、セキュリティ | 行を消すと、あとの PR で頼む観点が減る。観点を減らす変更を、セキュリティの観点でも見る |
| 役やホストが実行するスクリプトと設定 | `common/guard/`、`common/shell/`、`common/codex/` | コード、セキュリティ | ガード、役のシェルの環境、Codex の設定で、権限と書き込みの許可に関わる |
| 起動と見張りのスクリプト | `common/host/`、`common/monitor/`、`vm/` | コード、セキュリティ、性能 | 権限に関わることに加え、デーモンの起動と見張りの待ち時間、VM の準備の時間に関わる |
| セットアップのスクリプト | `setup.sh`、`install.sh`、`lib/` | コード、セキュリティ | エージェントとオートパイロットの登録、認証の確認、導入するファイルの取得に関わる |

文書・役のひな形（`common/agents/*.md`）・共通スキル（`common/skills/`）・プロジェクトのひな形（`skeleton/`）・テスト・開発用のスクリプト（`scripts/`）には、行を置かない。既定の文書・テスト・ソースの行で、コードの観点だけになるためである。

### 当てた結果

設計の時点のすべてのファイル（`git ls-files` の 752 件と、この対応のファイル）に、`squad-review-next` の当て方で対応を当てた。対応のファイルがないときは、34 件が対応に当たらない。

| 頼む観点 | ファイルの数 | 主なファイル |
| --- | --- | --- |
| コード | 700 | すべての `*.md`・`docs/`・`common/agents/`・`common/skills/`・`skeleton/`・`tests/`・`scripts/`・`MANIFEST` |
| コード、セキュリティ | 32 | `.github/`・`common/guard/`・`common/shell/`・`common/codex/`・`setup.sh`・`install.sh`・`lib/`・`.agents/review-paths` |
| コード、セキュリティ、性能 | 20 | `common/host/`・`common/monitor/`・`vm/` |

`*.md` は、行を置いたディレクトリの下にない。このため、文書・役のひな形・共通スキルの文の変更は、`MANIFEST` を作り直して積んでもコードの観点だけを頼む。

## テスト

対応を保つテスト `tests/own-review-paths-test.sh` を足す。`squad-review-next` から既定の対応と当て方の処理を取り出し、このリポジトリのファイルに当てる。当て方を写さずに取り出すのは、テストと見張りで当て方が食い違わないようにするためである。

| 確認すること | 失敗したときに直すこと |
| --- | --- |
| 対応のファイルを読める（形の誤りがない） | 誤った行を直す |
| `git ls-files` のすべてのファイルが、どれかの対応に当たる | 新しく足したファイルの場所に行を足す |
| すべての `*.md` が、コードの観点だけになる | `*.md` に当たる行を外すか、場所を絞る |
| `common/guard/`・`common/shell/`・`common/codex/`・`setup.sh`・`install.sh`・`lib/` のファイルが、セキュリティを含む | 外れた行を戻す |
| `common/host/`・`common/monitor/`・`vm/` のファイルが、セキュリティと性能を含む | 外れた行を戻す |

2 つ目の確認は、ファイルを足した PR で、対応に当たらないファイルを見つける。当たらないファイルがあると、すべての観点を頼む状態に黙って戻るためである。名前は `own-review-paths` を含むので、対応のファイルかこの文書を変えた PR では関連テストに選ばれる。テストの全件は CI が流す。

`tests/test-weights` には、[テストを書く決まり](../CONTRIBUTING.md#テストを書く決まり)に従い、重み（macOS の CI での秒数の目安）の行を足す。

## 変更の一覧

実装で変えるファイルは、次の 4 つである。ほかのファイルは変えない。

| ファイル | 変えること |
| --- | --- |
| `.agents/review-paths` | 新しく置く。中身は[ファイルの全文](#ファイルの全文)のとおり |
| `tests/own-review-paths-test.sh` | 新しく置く。[テスト](#テスト)の 5 つを確認する |
| `tests/test-weights` | 上のテストの重みの行を足す |
| `MANIFEST` | `bash scripts/manifest.sh` で作り直す |

## 互換性と影響を受ける利用者

導入済みのプロジェクトの動作は変わらない。変わるのは、このリポジトリの PR で頼む観点だけである。既定の対応、`squad-review-next` の処理、プロジェクトのひな形、セットアップが配置・登録するものは変えない。

対応は PR の base から読むので、対応のファイルを足す PR では効かず、すべての観点を頼む。マージしたあとの PR から効く。

影響を受けるのは、原本を変える人である。重要のマークのない PR で、文書だけの変更はコードの観点だけになり、ほかの観点の結果を待たなくなる。新しい場所にファイルを足すときは、この対応にも行を足す。

## 残る危うさ

次の 2 つは、この対応で残る。どちらも、テストで見つけるか、行を足して直す。

1 つ目は、行を置いたディレクトリ（`vm/`・`common/monitor/` など）の下に足した `*.md` である。そのファイルはディレクトリの行に当たり、コードのほかの観点も頼む。観点が増える向きなのでレビューは抜けず、テストの 3 つ目の確認が失敗する。行を絞るか、文書をほかへ置く。

2 つ目は、開発用のスクリプト（`scripts/`）が、コードの観点だけになることである。`scripts/release.sh` などは人間が手元で流すもので、役やホストが実行しないためである。役やホストが流すスクリプトを `scripts/` に足すときは、行を足す。

## 検討した案

対応の置き場所と行の選び方について、次の案を選ばなかった。

| 案 | 選ばなかった理由 |
| --- | --- |
| 原本の既定の対応に `MANIFEST` などを足す | 導入先のプロジェクトの観点の選び方が変わる。`MANIFEST` はこのリポジトリだけの生成物である |
| 名簿からセキュリティや性能の役を外す | スクリプトの変更でも観点が抜ける。人間の判断なしに観点を減らすことになる |
| `*.md` の行をこの対応に置き、文書をコードの観点だけに固定する | 既定の行と同じ結果で、行が増えるだけである。行を置いたディレクトリの下の `*.md` には、ディレクトリの行と合わさるので効かない |
| ディレクトリの行を置かず、スクリプトを既定のソースの行（`*.sh` など）に任せる | 拡張子のないスクリプト（`common/monitor/` の見張りなど）が対応に当たらない。当たる `*.sh` も、コードの観点だけになる |
| 対応のファイルの行を、レビューのたびに人が見直す | 新しいファイルが当たらないことは、テストで機械的に見つかる。人の見直しは読み落とすと働かない |
