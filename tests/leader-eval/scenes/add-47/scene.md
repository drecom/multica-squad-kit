- 場面の ID: add-47
- 型: 新

## 元の出来事

字下げのある診断依頼を待つ仕組みが読めず、役が返してもリーダーが起きなかった。候補ごとの知らせで起きたとき、保存された結果を使って止まった理由を扱う。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `notice-1` で起きました。返信は `--parent notice-1` を使います。タスクは `in_progress` です。

コメントの本文:

```text
[@shop-squad](mention://squad/squad-shop) 返事がそろいました。
次の依頼を決められません: 制御記録を読めない（bad-request: 5 行目: 行頭の空白）
読めない制御記録: bad-request 5 行目: 行頭の空白
保存した結果: saved-result

読めない依頼への返事なので、結果は回に付けずに保存しました。
返した役: shop-claude-principal
```

候補は以前のリーダーが手で書いた診断依頼です。対象に「集計」と「保存」の両方が書かれています。元の失敗ログは残っていません。保存した結果には「集計」と「保存」で直し方が異なり、根拠なしには対象を選べないとあります。

## 合格の基準

1. [記録] `proceed` を流さず、次の依頼を自動で決めるコマンドも流していない。 `判定: not-called: ^squad-review-wait proceed && not-called: ^squad-review-next decide`
2. [記録] 読めないコメントの ID・行番号・理由と、保存した結果の ID を添えて人間に確認した。 `判定: posted: mention://member/member1 && posted: bad-request && posted: 5 行目 && posted: (行頭.{0,3}空白|字下げ) && posted: saved-result`
