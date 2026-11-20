#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/metrics-breakdown.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
export PYTHONDONTWRITEBYTECODE=1

# A synthetic snapshot (project key demo, member key x), not a fabricated CLI response.
fixtures="$root/tests/fixtures/metrics/breakdown"
breakdown() {
	python3 "$root/scripts/metrics.py" breakdown "$1" \
		--cutoff 2026-01-01T00:00:00Z --project-key demo --member-key x --output "$2"
}

breakdown "$fixtures/snapshot.json" "$test_dir/first"
breakdown "$fixtures/snapshot.json" "$test_dir/second"
for file in breakdown.json breakdown.md breakdown-tasks.json; do
	cmp "$test_dir/first/$file" "$fixtures/$file"
	cmp "$test_dir/first/$file" "$test_dir/second/$file"
done
[ "$(ls "$test_dir/first" | LC_ALL=C sort | tr '\n' ' ')" = 'breakdown-tasks.json breakdown.json breakdown.md ' ]
echo 'PASS metrics-breakdown: 固定した見本の結果が期待する結果と 1 バイトも違わず、2 回流しても同じ'

python3 "$root/tests/metrics-breakdown-check.py" "$root" "$test_dir/first"
python3 "$root/tests/metrics-anonymize-check.py" "$root" "$test_dir"

# A snapshot without marks_version 2 (none, or the old 1), or without a field --marks adds, stops and writes nothing.
for case in old version-1 missing-field; do
	if [ "$case" = old ]; then
		input="$root/tests/fixtures/metrics/snapshot.json"
	elif [ "$case" = version-1 ]; then
		input="$test_dir/version-1.json"
		python3 - "$fixtures/snapshot.json" "$input" <<'PY'
import json
import sys

snapshot = json.load(open(sys.argv[1]))
snapshot["marks_version"] = 1
json.dump(snapshot, open(sys.argv[2], "w"))
PY
	else
		input="$test_dir/missing-field.json"
		python3 - "$fixtures/snapshot.json" "$input" <<'PY'
import json
import sys

snapshot = json.load(open(sys.argv[1]))
del snapshot["comments"][0]["marks"]
json.dump(snapshot, open(sys.argv[2], "w"))
PY
	fi
	if breakdown "$input" "$test_dir/stopped-$case" 2> "$test_dir/stopped-$case.err"; then
		echo "FAIL metrics-breakdown: $case のスナップショットで止まらなかった" >&2
		exit 1
	fi
	grep -q -- '--marks' "$test_dir/stopped-$case.err"
	for file in breakdown.json breakdown.md breakdown-tasks.json; do
		[ ! -e "$test_dir/stopped-$case/$file" ]
	done
done
echo 'PASS metrics-breakdown: marks_version のないスナップショットと marks_version 1 のスナップショットと足した欄のないスナップショットで止まり、取り直しを伝える'
