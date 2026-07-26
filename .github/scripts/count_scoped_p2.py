#!/usr/bin/env python3
"""Count Omar Gate P2 findings scoped to files in the PR diff.

Reads:
  /tmp/omar-scope/comment.md   — the full Omar Gate PR comment markdown
  /tmp/omar-scope/changed.txt  — newline-delimited list of PR-touched files

Writes a single integer to stdout: the number of P2 findings whose file
path appears in the PR diff.

Rationale: the repo's P2_MAX=5 policy was blocking merges even when every
P2 was on a file untouched by the PR (pre-existing noise on unrelated
pages / docs). Scoping the count to files actually in the diff keeps the
gate effective on regressions while letting clean PRs merge.

Invoked from .github/workflows/omar-gate.yml 'Compute PR-scoped P2 count'
step.
"""

from __future__ import annotations

import pathlib
import re
import sys


def _top_findings_section(comment: str) -> str:
    marker = "### Top Findings"
    start = comment.find(marker)
    if start == -1:
        return comment
    tail = comment[start + len(marker) :]
    next_heading = re.search(r"^#{2,3}\s+", tail, flags=re.MULTILINE)
    if next_heading is None:
        return tail
    return tail[: next_heading.start()]


def count_scoped_p2(comment: str, changed: set[str]) -> int:
    # Only count the canonical Top Findings list. The Omar comment repeats the
    # same findings in a reviewer brief, and counting both can make scoped P2
    # exceed Omar's own total P2 count.
    findings = _top_findings_section(comment)
    pattern = re.compile(r"\*\*P2\*\*\s+(?:\[)?[`]([^`]+?)[`]", re.MULTILINE)
    seen: set[str] = set()
    scoped = 0
    for match in pattern.finditer(findings):
        locator = match.group(1).strip()
        path = re.sub(r":\d+(?:-\d+)?$", "", locator)
        if locator in seen:
            continue
        seen.add(locator)
        if path in changed:
            scoped += 1
    return scoped


def main() -> int:
    comment_path = pathlib.Path("/tmp/omar-scope/comment.md")
    changed_path = pathlib.Path("/tmp/omar-scope/changed.txt")
    if not comment_path.exists():
        print("0")
        return 0
    comment = comment_path.read_text(encoding="utf-8")
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
        # No diff data — caller should fall back to total count. Emit 0 so
        # the downstream step knows the scoped path produced nothing usable.
        print("0")
        return 0
    print(count_scoped_p2(comment, changed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
