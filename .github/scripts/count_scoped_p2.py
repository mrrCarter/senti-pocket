#!/usr/bin/env python3
"""Count Omar Gate P2 findings scoped to files in the PR diff.

Reads:
  /tmp/omar-scope/findings.jsonl - Omar Gate FINDINGS.jsonl from the action artifact
  /tmp/omar-scope/changed.txt    - newline-delimited list of PR-touched files

Writes a single integer to stdout: the number of P2 findings whose file
path appears in the PR diff.

Rationale: the repo's full-repo Omar baseline can include recurring P2s on
files untouched by a given PR. Scoping the count to files actually in the diff
keeps the gate effective on regressions while letting clean PRs merge.
"""

from __future__ import annotations

import json
import pathlib
import sys


def _finding_path(payload: dict[str, object]) -> str:
    scope = payload.get("scope")
    if isinstance(scope, dict):
        for key in ("path", "file", "file_path"):
            value = scope.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
    for key in ("path", "file", "file_path"):
        value = payload.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    location = payload.get("location")
    if isinstance(location, dict):
        value = location.get("path") or location.get("file")
        if isinstance(value, str) and value.strip():
            return value.strip()
    return ""


def main() -> int:
    findings_path = pathlib.Path("/tmp/omar-scope/findings.jsonl")
    changed_path = pathlib.Path("/tmp/omar-scope/changed.txt")
    if not findings_path.exists():
        print("0")
        return 0
    changed = {
        line.strip()
        for line in (
            changed_path.read_text(encoding="utf-8").splitlines()
            if changed_path.exists()
            else []
        )
        if line.strip()
    }
    if not changed:
        print("0")
        return 0

    seen: set[tuple[str, int]] = set()
    scoped = 0
    for index, line in enumerate(findings_path.read_text(encoding="utf-8").splitlines()):
        raw = line.strip()
        if not raw:
            continue
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if not isinstance(payload, dict):
            continue
        severity = str(payload.get("severity") or "").strip().upper()
        if severity != "P2":
            continue
        path = _finding_path(payload)
        key = (path, index)
        if key in seen:
            continue
        seen.add(key)
        if path in changed:
            scoped += 1
    print(scoped)
    return 0


if __name__ == "__main__":
    sys.exit(main())
