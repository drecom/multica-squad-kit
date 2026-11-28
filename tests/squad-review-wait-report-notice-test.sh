#!/usr/bin/env bash
# 字下げの根拠がある診断の依頼に役が返したとき、report が今どう動くかを確認する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source "$root/tests/review-wait-test-lib.sh"

diagnosis_body="見直しの種類: 診断
診断の依頼: 2 回目。失敗: 同じ誤り 検証
返事を待つ役: [@qa](mention://agent/$b)

続いた失敗の根拠:
  - 同じ検証が失敗した"

report_diagnosis() {
	reset_calls
	build_comments "$@" | with_raw diagnosis orchestrator agent 10 "$diagnosis_body" >"$test_dir/comments.1.json"
	cp "$test_dir/comments.1.json" "$test_dir/comments.json"
	bash "$script" report test-issue diagnosis "$test_dir/result.md"
	assert_jq -s '.[0].body == "/note\nqa result\n返事の回: round\n"
		and (.[0].args | index("--parent") as $i | .[$i+1] == "diagnosis")' "$test_dir/posted.jsonl"
	[[ $(posted_decide_count) == 0 && -z $(decide_calls) ]]
}

report_diagnosis
assert_jq -s 'length == 2 and (.[1].body | startswith(
	"[@demo-squad](mention://squad/squad-test) 返事がそろいました。\n次の依頼を決められません: 制御記録を読めない（diagnosis: 6 行目: 行頭の空白）\n"))' "$test_dir/posted.jsonl"
echo 'PASS report: 前の回に記録がなければ、結果は前の回に付き、字下げの理由を知らせる'

report_diagnosis result:a:review-result:3 result:b:qa-result:4 \
	decide:a:previous-decision:5 next:a:previous-next:6 ready:a:previous-notice:7
assert_jq -s 'length == 1' "$test_dir/posted.jsonl"
echo 'PASS report: 前の回に次の依頼・決める記録・知らせがあれば、結果は前の回に付き、新しい知らせは出ない'
