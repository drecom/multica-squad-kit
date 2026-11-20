"""Emit metrics cases only when their keys and types match captured CLI responses."""

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def same_shape(original, candidate, missing=False, key=None):
    # The captured runs all failed nowhere and were all started by a comment, so every sample has
    # error: null and a string trigger_comment_id. A failed run carries a string error, and a run
    # not started by a comment has a null trigger_comment_id. Only those two keys may differ so.
    if key == "error" and original is None and isinstance(candidate, str):
        return True
    if key == "trigger_comment_id" and isinstance(original, str) and candidate is None:
        return True
    if isinstance(original, dict):
        if not isinstance(candidate, dict) or candidate.keys() - original.keys():
            return False
        if not missing and original.keys() - candidate.keys() - {"usage"}:
            return False
        return all(same_shape(original[name], value, missing, name) for name, value in candidate.items())
    if isinstance(original, list):
        return isinstance(candidate, list) and all(
            any(same_shape(before, value, missing) for before in original) for value in candidate)
    return type(original) is type(candidate)


def run(work, action, name, file):
    if action != "emit":
        raise ValueError("unknown metrics fixture action")
    candidates = json.loads(Path(file).read_text())
    originals = json.loads((ROOT / "tests/fixtures/cli" / (name + ".json")).read_text())
    missing = (Path(work) / "allow-missing-fields").exists()
    if not any(same_shape(original, candidates, missing) for original in originals):
        raise AssertionError(f"CLI の実物の見本と鍵・型が違います: {name}")
    print(json.dumps(candidates, ensure_ascii=False))
