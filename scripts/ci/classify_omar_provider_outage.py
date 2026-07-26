from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


class ProviderOutageClassifierError(ValueError):
    pass


@dataclass(frozen=True)
class ProviderOutageClassification:
    provider_outage_break_glass: bool
    reason: str
    blocking_count: int
    p0_count: int
    p1_count: int
    p2_count: int


_CAPACITY_MARKERS = (
    "429",
    "capacity",
    "consumer_suspended",
    "credit balance",
    "credits",
    "insufficient_quota",
    "permission_denied",
    "provider unavailable",
    "quota",
    "rate limit",
    "suspended",
)

_LLM_FAILURE_MARKERS = (
    "blocking merge per fail-closed policy",
    "fallback failed",
    "llm analysis failed",
    "primary failed",
)


def _load_findings(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        raise ProviderOutageClassifierError(f"findings file not found: {path}")

    findings: list[dict[str, Any]] = []
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        stripped = line.strip()
        if not stripped:
            continue
        try:
            payload = json.loads(stripped)
        except json.JSONDecodeError as exc:
            raise ProviderOutageClassifierError(
                f"invalid findings JSON on line {line_number}"
            ) from exc
        if not isinstance(payload, dict):
            raise ProviderOutageClassifierError(
                f"finding on line {line_number} is not a JSON object"
            )
        findings.append(payload)
    return findings


def _load_run_summary(path: Path | None) -> dict[str, Any]:
    if path is None:
        return {}
    if not path.exists():
        raise ProviderOutageClassifierError(f"run summary file not found: {path}")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ProviderOutageClassifierError("invalid RUN_SUMMARY.json") from exc
    if not isinstance(payload, dict):
        raise ProviderOutageClassifierError("RUN_SUMMARY.json is not a JSON object")
    return payload


def _finding_path(finding: dict[str, Any]) -> str:
    explicit = str(finding.get("file_path") or "").strip()
    if explicit:
        return explicit
    scope = finding.get("scope")
    if isinstance(scope, dict):
        return str(scope.get("path") or "").strip()
    return ""


def _finding_source(finding: dict[str, Any]) -> str:
    return str(finding.get("source") or finding.get("provenance") or "").strip()


def _finding_message(finding: dict[str, Any]) -> str:
    return str(
        finding.get("message")
        or finding.get("impact")
        or finding.get("description")
        or finding.get("title")
        or ""
    ).lower()


def _summary_int(summary: dict[str, Any], key: str) -> int | None:
    value = summary.get(key)
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.strip().isdigit():
        return int(value.strip())
    return None


def _summary_count(summary: dict[str, Any], severity: str) -> int | None:
    counts = summary.get("counts")
    if not isinstance(counts, dict):
        return None
    value = counts.get(severity)
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.strip().isdigit():
        return int(value.strip())
    return None


def _is_managed_billing_denied_no_findings(
    findings: list[dict[str, Any]],
    counts: dict[str, int],
    run_summary: dict[str, Any],
) -> bool:
    if not run_summary or findings:
        return False
    if any(counts[severity] != 0 for severity in ("P0", "P1", "P2")):
        return False
    if str(run_summary.get("status") or "").strip().lower() != "failed":
        return False
    if str(run_summary.get("progress") or "").strip().lower() != "failed:billing-denied":
        return False
    if str(run_summary.get("gate_status") or "").strip().lower() != "error":
        return False
    if _summary_int(run_summary, "backend_findings_count") != 0:
        return False
    if _summary_int(run_summary, "local_findings_count") != 0:
        return False
    if any((_summary_count(run_summary, severity) != 0) for severity in ("P0", "P1", "P2", "P3")):
        return False

    policy = run_summary.get("llm_policy")
    if not isinstance(policy, dict):
        return False
    if policy.get("sentinelayer_managed_llm") is not True:
        return False
    if str(policy.get("llm_failure_policy") or "").strip().lower() != "block":
        return False
    return True


def classify_provider_outage(
    findings: list[dict[str, Any]],
    run_summary: dict[str, Any] | None = None,
) -> ProviderOutageClassification:
    run_summary = run_summary or {}
    counts = {"P0": 0, "P1": 0, "P2": 0}
    blocking: list[dict[str, Any]] = []
    for finding in findings:
        severity = str(finding.get("severity") or "").upper()
        if severity in counts:
            counts[severity] += 1
            blocking.append(finding)

    if counts["P1"] or counts["P2"]:
        return ProviderOutageClassification(
            provider_outage_break_glass=False,
            reason="blocking_non_p0_findings_present",
            blocking_count=len(blocking),
            p0_count=counts["P0"],
            p1_count=counts["P1"],
            p2_count=counts["P2"],
        )

    if _is_managed_billing_denied_no_findings(findings, counts, run_summary):
        return ProviderOutageClassification(
            provider_outage_break_glass=True,
            reason="managed_billing_denied_no_findings",
            blocking_count=0,
            p0_count=0,
            p1_count=0,
            p2_count=0,
        )

    if counts["P0"] != 1 or len(blocking) != 1:
        return ProviderOutageClassification(
            provider_outage_break_glass=False,
            reason="expected_exactly_one_p0_llm_failure",
            blocking_count=len(blocking),
            p0_count=counts["P0"],
            p1_count=counts["P1"],
            p2_count=counts["P2"],
        )

    finding = blocking[0]
    category = str(finding.get("category") or "")
    source = _finding_source(finding)
    file_path = _finding_path(finding)
    message = _finding_message(finding)
    if category != "LLM Failure" or source != "system" or file_path != "<system>":
        return ProviderOutageClassification(
            provider_outage_break_glass=False,
            reason="p0_is_not_system_llm_failure",
            blocking_count=len(blocking),
            p0_count=counts["P0"],
            p1_count=counts["P1"],
            p2_count=counts["P2"],
        )

    if not all(marker in message for marker in _LLM_FAILURE_MARKERS):
        return ProviderOutageClassification(
            provider_outage_break_glass=False,
            reason="llm_failure_message_missing_fail_closed_markers",
            blocking_count=len(blocking),
            p0_count=counts["P0"],
            p1_count=counts["P1"],
            p2_count=counts["P2"],
        )

    if not any(marker in message for marker in _CAPACITY_MARKERS):
        return ProviderOutageClassification(
            provider_outage_break_glass=False,
            reason="llm_failure_not_provider_capacity_class",
            blocking_count=len(blocking),
            p0_count=counts["P0"],
            p1_count=counts["P1"],
            p2_count=counts["P2"],
        )

    return ProviderOutageClassification(
        provider_outage_break_glass=True,
        reason="single_system_llm_provider_outage",
        blocking_count=1,
        p0_count=1,
        p1_count=0,
        p2_count=0,
    )


def _write_github_outputs(path: Path | None, result: ProviderOutageClassification) -> None:
    lines = [
        f"provider_outage_break_glass={str(result.provider_outage_break_glass).lower()}",
        f"reason={result.reason}",
        f"blocking_count={result.blocking_count}",
        f"p0_count={result.p0_count}",
        f"p1_count={result.p1_count}",
        f"p2_count={result.p2_count}",
    ]
    if path is None:
        return
    with path.open("a", encoding="utf-8") as output_file:
        for line in lines:
            output_file.write(f"{line}\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Classify whether a failed managed Omar run is provider-outage-only."
    )
    parser.add_argument(
        "--findings",
        required=True,
        help="Path to Omar FINDINGS.jsonl from the managed run.",
    )
    parser.add_argument(
        "--github-output",
        default="",
        help="Optional GitHub Actions output file path.",
    )
    parser.add_argument(
        "--run-summary",
        default="",
        help="Optional RUN_SUMMARY.json from the managed Omar run.",
    )
    args = parser.parse_args(argv)

    try:
        findings = _load_findings(Path(args.findings))
        run_summary = _load_run_summary(Path(args.run_summary)) if args.run_summary else {}
        result = classify_provider_outage(findings, run_summary)
    except ProviderOutageClassifierError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 2

    _write_github_outputs(
        Path(args.github_output) if args.github_output else None,
        result,
    )
    print(
        "provider_outage_break_glass="
        f"{str(result.provider_outage_break_glass).lower()} reason={result.reason} "
        f"blocking={result.blocking_count} P0={result.p0_count} "
        f"P1={result.p1_count} P2={result.p2_count}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
