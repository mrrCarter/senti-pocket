from __future__ import annotations

import argparse
import fnmatch
import re
import sys
from dataclasses import dataclass
from pathlib import Path


class ForbiddenOmarSurfaceError(ValueError):
    pass


@dataclass(frozen=True)
class PatternRule:
    rule_id: str
    regex: re.Pattern[str]
    description: str


@dataclass(frozen=True)
class Finding:
    rule_id: str
    path: str
    line: int
    snippet: str


FORBIDDEN_PATTERNS = (
    PatternRule(
        rule_id="legacy-review-acronym",
        regex=re.compile(r"\b" + "M" + "AM" + r"\b"),
        description="old public review acronym",
    ),
    PatternRule(
        rule_id="legacy-review-name",
        regex=re.compile("Multi-Agent " + "Review"),
        description="old public review name",
    ),
    PatternRule(
        rule_id="legacy-authoritative-marker",
        regex=re.compile("sentinelayer:omar-gate:" + "authoritative-review"),
        description="old authoritative marker",
    ),
    PatternRule(
        rule_id="legacy-summary-marker",
        regex=re.compile("sentinelayer-omar-" + "summary"),
        description="old summary marker",
    ),
    PatternRule(
        rule_id="legacy-wait-helper",
        regex=re.compile("wait_for_" + "authoritative"),
        description="old wait helper",
    ),
    PatternRule(
        rule_id="legacy-comment-flag",
        regex=re.compile("--upsert" + "-comment"),
        description="old comment upsert flag",
    ),
)

FORBIDDEN_FILENAMES = (
    "wait_for_" + "authoritative" + "_omar_review.py",
)

TEXT_SUFFIXES = {
    ".cfg",
    ".css",
    ".html",
    ".js",
    ".json",
    ".jsx",
    ".md",
    ".mjs",
    ".ps1",
    ".py",
    ".sh",
    ".toml",
    ".ts",
    ".tsx",
    ".txt",
    ".yaml",
    ".yml",
}

TEXT_FILENAMES = {
    "Dockerfile",
    "Makefile",
}

EXCLUDED_DIRS = {
    ".git",
    ".mypy_cache",
    ".pytest_cache",
    ".ruff_cache",
    ".sentinelayer",
    ".terraform",
    ".venv",
    "__pycache__",
    "build",
    "coverage",
    "dist",
    "node_modules",
    "site-packages",
    "venv",
}

EXCLUDED_PATH_GLOBS = {
    "package-lock.json",
    "pnpm-lock.yaml",
    "yarn.lock",
    "*.lock",
    "tasks/**",
    "test/**",
    "tests/**",
    "**/__tests__/**",
    "**/fixtures/**",
    "**/*.snap",
}


def _relative_path(path: Path, root: Path) -> str:
    return path.relative_to(root).as_posix()


def _is_text_candidate(path: Path) -> bool:
    return path.name in TEXT_FILENAMES or path.suffix.lower() in TEXT_SUFFIXES


def _is_excluded(rel_path: str) -> bool:
    parts = set(rel_path.split("/"))
    if parts & EXCLUDED_DIRS:
        return True
    return any(fnmatch.fnmatch(rel_path, pattern) for pattern in EXCLUDED_PATH_GLOBS)


def _iter_candidate_files(root: Path) -> list[Path]:
    candidates: list[Path] = []
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        rel_path = _relative_path(path, root)
        if _is_excluded(rel_path):
            continue
        if _is_text_candidate(path):
            candidates.append(path)
    return candidates


def _scan_text(rel_path: str, text: str) -> list[Finding]:
    findings: list[Finding] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        for rule in FORBIDDEN_PATTERNS:
            if rule.regex.search(line):
                findings.append(
                    Finding(
                        rule_id=rule.rule_id,
                        path=rel_path,
                        line=line_number,
                        snippet=line.strip()[:220],
                    )
                )
    return findings


def scan_repo(root: Path) -> list[Finding]:
    root = root.resolve()
    findings: list[Finding] = []
    for path in _iter_candidate_files(root):
        rel_path = _relative_path(path, root)
        for forbidden_name in FORBIDDEN_FILENAMES:
            if path.name == forbidden_name:
                findings.append(
                    Finding(
                        rule_id="legacy-wait-helper-file",
                        path=rel_path,
                        line=1,
                        snippet=path.name,
                    )
                )
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        findings.extend(_scan_text(rel_path, text))
    return findings


def _assert_finds(rule_id: str, text: str) -> None:
    findings = _scan_text("fixture.txt", text)
    if not any(finding.rule_id == rule_id for finding in findings):
        raise AssertionError(f"self-test did not trigger {rule_id}")


def _run_self_tests() -> None:
    _assert_finds("legacy-review-acronym", "old " + "M" + "AM" + " wording")
    _assert_finds("legacy-review-name", "Omar " + "Multi-Agent " + "Review")
    _assert_finds(
        "legacy-authoritative-marker",
        "<!-- " + "sentinelayer:omar-gate:" + "authoritative-review" + " -->",
    )
    _assert_finds("legacy-summary-marker", "<!-- " + "sentinelayer-omar-" + "summary" + " -->")
    _assert_finds("legacy-wait-helper", "python scripts/ci/" + "wait_for_" + "authoritative")
    _assert_finds("legacy-comment-flag", "--upsert" + "-comment")

    clean_findings = _scan_text(
        "clean.md",
        "Omar Gate Review uses direct artifacts and managed LLM checks.",
    )
    if clean_findings:
        raise AssertionError("self-test clean fixture produced findings")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Block obsolete Omar public-surface markers from source, docs, and CI."
    )
    parser.add_argument("--root", default=".", help="Repository root to scan.")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        _run_self_tests()

    findings = scan_repo(Path(args.root))
    if findings:
        print("::error::Forbidden Omar surface scan failed.", file=sys.stderr)
        for finding in findings:
            print(
                f"::error file={finding.path},line={finding.line}::{finding.rule_id}: {finding.snippet}",
                file=sys.stderr,
            )
        return 1
    print("Forbidden Omar surface scan passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
