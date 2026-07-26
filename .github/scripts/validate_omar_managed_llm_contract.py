#!/usr/bin/env python3
"""Fail closed if AIdenID's Omar workflow drifts to the local-only bridge."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ACTION_PIN_RE = re.compile(
    r"uses:\s*mrrCarter/sentinelayer-v1-action@[0-9a-f]{40}\b"
)
MANAGED_TRUE_RE = re.compile(
    r"sentinelayer_managed_llm\s*:\s*['\"]?true['\"]?", re.IGNORECASE
)
MANAGED_FALSE_RE = re.compile(
    r"sentinelayer_managed_llm\s*:\s*['\"]?false['\"]?", re.IGNORECASE
)
REQUESTED_MANAGED_TRUE_RE = re.compile(
    r"REQUESTED_MANAGED_LLM\s*:\s*['\"]?true['\"]?", re.IGNORECASE
)
FAILURE_POLICY_BLOCK_RE = re.compile(
    r"llm_failure_policy\s*:\s*block\b", re.IGNORECASE
)
LEGACY_LLM_INPUT_RE = re.compile(
    r"^\s*(openai_api_key|anthropic_api_key|google_api_key|llm_provider)\s*:",
    re.MULTILINE,
)


def validate_workflow_text(text: str) -> list[str]:
    errors: list[str] = []
    if not ACTION_PIN_RE.search(text):
        errors.append("omar-gate.yml must pin mrrCarter/sentinelayer-v1-action to a full 40-character SHA.")
    if not MANAGED_TRUE_RE.search(text):
        errors.append("omar-gate.yml must request sentinelayer_managed_llm: true.")
    if MANAGED_FALSE_RE.search(text):
        errors.append("omar-gate.yml must not set sentinelayer_managed_llm: false.")
    if LEGACY_LLM_INPUT_RE.search(text):
        errors.append("omar-gate.yml must not pass legacy BYOK inputs openai_api_key/anthropic_api_key/google_api_key/llm_provider.")
    if "Assert Omar LLM model contract is active" not in text:
        errors.append("omar-gate.yml must keep the Omar LLM model contract assertion step.")
    if not REQUESTED_MANAGED_TRUE_RE.search(text):
        errors.append("Omar assertion must expect REQUESTED_MANAGED_LLM: true.")
    if not FAILURE_POLICY_BLOCK_RE.search(text):
        errors.append("Omar workflow must keep llm_failure_policy: block.")
    return errors


def _run_self_test() -> None:
    good = """
    - name: Run Omar Gate
      uses: mrrCarter/sentinelayer-v1-action@4cb3063e04e3b899981b25f6918b26f70d35a8d4
      with:
        sentinelayer_managed_llm: "true"
        llm_failure_policy: block
    - name: Assert Omar LLM model contract is active
      env:
        REQUESTED_MANAGED_LLM: "true"
    """
    bad = good.replace('sentinelayer_managed_llm: "true"', 'sentinelayer_managed_llm: "false"')
    if validate_workflow_text(good):
        raise AssertionError("expected valid managed-LLM Omar workflow fixture")
    if not validate_workflow_text(bad):
        raise AssertionError("expected managed=false fixture to fail validation")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--workflow",
        default=".github/workflows/omar-gate.yml",
        help="Path to the Omar Gate workflow YAML.",
    )
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        _run_self_test()
        return 0

    workflow_path = Path(args.workflow)
    if not workflow_path.exists():
        print(f"::error::Omar workflow not found: {workflow_path}")
        return 1

    errors = validate_workflow_text(workflow_path.read_text(encoding="utf-8"))
    for error in errors:
        print(f"::error::{error}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
