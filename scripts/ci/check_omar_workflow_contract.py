from __future__ import annotations

import argparse
import sys
from pathlib import Path


class OmarWorkflowContractError(ValueError):
    pass


BRIDGE_OR_BROKEN_MARKERS = (
    "GitHub App bridge",
    "thin GitHub App bridge",
    "Playwright + SBOM + model policy",
    "721bc7efe1402fcce416becea3d247b838119ed2",
    "fc444dee5bab4c79136775eb6930f1dea020d07c",
)


def _line_has_managed_llm_enabled(line: str) -> bool:
    normalized = line.split("#", 1)[0].strip().lower().replace("'", '"')
    return normalized in {
        'sentinelayer_managed_llm: "true"',
        "sentinelayer_managed_llm: true",
    }


# senti-pocket runs a DETERMINISTIC codex contract (owner override): no
# OpenAI/Google conditional. Provider is pinned to openai, model/codex_model/
# model_fallback are all pinned to gpt-5.3-codex, use_codex is "true", and the
# managed-capacity fallback is enabled whenever SENTINELAYER_TOKEN is present.
ALLOWED_OPENAI_API_KEY_LINE = "openai_api_key: ${{ secrets.OPENAI_API_KEY }}"
ALLOWED_LLM_PROVIDER_LINE = "llm_provider: openai"
ALLOWED_MANAGED_LLM_LINE = "sentinelayer_managed_llm: ${{ secrets.SENTINELAYER_TOKEN != '' }}"
ALLOWED_MODEL_LINE = "model: gpt-5.3-codex"
ALLOWED_MODEL_FALLBACK_LINE = "model_fallback: gpt-5.3-codex"
ALLOWED_USE_CODEX_LINE = 'use_codex: "true"'
TELEMETRY_LOG_DOWNLOAD_FRAGMENTS = (
    "curl --silent --show-error --location --fail-with-body",
    "--proto-redir '=https' --max-redirs 3",
    '--header "Authorization: Bearer ${GH_TOKEN}"',
    '"https://api.github.com/repos/${REPOSITORY}/actions/jobs/${job_id}/logs"',
)


def _repo_llm_configured(workflow_text: str) -> bool:
    return (
        ALLOWED_OPENAI_API_KEY_LINE in workflow_text
        and ALLOWED_LLM_PROVIDER_LINE in workflow_text
        and ALLOWED_MANAGED_LLM_LINE in workflow_text
        and ALLOWED_MODEL_LINE in workflow_text
        and ALLOWED_MODEL_FALLBACK_LINE in workflow_text
        and ALLOWED_USE_CODEX_LINE in workflow_text
    )


def _is_job_start(line: str) -> bool:
    stripped = line.strip()
    return (
        line.startswith("  ")
        and not line.startswith("    ")
        and stripped.endswith(":")
        and stripped[:-1].replace("_", "").replace("-", "").isalnum()
    )


def _find_omar_review_job_lines(lines: list[str]) -> list[str]:
    return _find_job_lines(lines, "omar-review")


def _find_job_lines(lines: list[str], job_id: str) -> list[str]:
    start = None
    for index, line in enumerate(lines):
        if line.rstrip() == f"  {job_id}:":
            start = index
            break

    if start is None:
        raise OmarWorkflowContractError(f"omar-gate.yml is missing jobs.{job_id}")

    end = len(lines)
    for index in range(start + 1, len(lines)):
        if _is_job_start(lines[index]):
            end = index
            break

    return lines[start:end]


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise OmarWorkflowContractError(message)


def _top_level_permissions_include_oidc_write(lines: list[str]) -> bool:
    permissions_start = None
    for index, line in enumerate(lines):
        if line.rstrip() == "permissions:":
            permissions_start = index
            break

    if permissions_start is None:
        return False

    for line in lines[permissions_start + 1 :]:
        if line.strip() == "" or line.lstrip().startswith("#"):
            continue
        if not line.startswith("  "):
            break
        if line.split("#", 1)[0].strip() == "id-token: write":
            return True

    return False


def _job_permissions_include_oidc_write(job_lines: list[str]) -> bool:
    permissions_start = None
    for index, line in enumerate(job_lines):
        if line.rstrip() == "    permissions:":
            permissions_start = index
            break

    if permissions_start is None:
        return False

    for line in job_lines[permissions_start + 1 :]:
        if line.strip() == "" or line.lstrip().startswith("#"):
            continue
        if not line.startswith("      "):
            break
        if line.split("#", 1)[0].strip() == "id-token: write":
            return True

    return False


def validate_omar_workflow_text(workflow_text: str) -> None:
    lines = workflow_text.splitlines()
    for marker in BRIDGE_OR_BROKEN_MARKERS:
        if marker in workflow_text:
            raise OmarWorkflowContractError(
                f"omar-gate.yml references bridge or broken Omar marker: {marker}"
            )

    for line in lines:
        stripped = line.split("#", 1)[0].strip()
        if stripped.startswith("pr_number:"):
            raise OmarWorkflowContractError(
                "full Omar action workflow must not pass bridge-only pr_number"
            )
        if stripped.startswith("openai_api_key:") and stripped != ALLOWED_OPENAI_API_KEY_LINE:
            raise OmarWorkflowContractError(
                "openai_api_key must come from secrets.OPENAI_API_KEY"
            )
        if stripped.startswith(
            ("anthropic_api_key:", "xai_api_key:", "google_api_key:")
        ):
            raise OmarWorkflowContractError(
                "deterministic codex Omar workflow must not pass non-OpenAI provider-key inputs"
            )
        if stripped.startswith("llm_provider:") and stripped != ALLOWED_LLM_PROVIDER_LINE:
            raise OmarWorkflowContractError(
                "llm_provider must be pinned to openai on the deterministic codex path"
            )
        if stripped.startswith("model:") and stripped != ALLOWED_MODEL_LINE:
            raise OmarWorkflowContractError(
                "model must be pinned to the deterministic codex model gpt-5.3-codex"
            )
        if stripped.startswith("model_fallback:") and stripped != ALLOWED_MODEL_FALLBACK_LINE:
            raise OmarWorkflowContractError(
                "model_fallback must be pinned to gpt-5.3-codex on the deterministic codex path"
            )
        if stripped.startswith("sentinelayer_managed_llm:") and stripped != ALLOWED_MANAGED_LLM_LINE:
            raise OmarWorkflowContractError(
                "sentinelayer_managed_llm must match the SENTINELAYER_TOKEN-present managed-capacity expression"
            )

    managed_llm_enabled = any(_line_has_managed_llm_enabled(line) for line in lines)
    repo_llm_configured = _repo_llm_configured(workflow_text)
    if managed_llm_enabled or not repo_llm_configured:
        raise OmarWorkflowContractError(
            "omar-gate.yml must use repo-owned OpenAI/Codex with Gemini fallback, and managed only when BYO keys are absent"
        )

    if not _top_level_permissions_include_oidc_write(lines):
        raise OmarWorkflowContractError(
            "top-level permissions must include id-token: write for managed/provenance-capable Omar scans"
        )

    omar_job_lines = _find_omar_review_job_lines(lines)
    if not _job_permissions_include_oidc_write(omar_job_lines):
        raise OmarWorkflowContractError(
            "jobs.omar-review.permissions must include id-token: write"
        )

    fork_job_lines = _find_job_lines(lines, "omar-fork-static")
    finalize_job_lines = _find_job_lines(lines, "omar-gate-finalize")
    fork_job_text = "\n".join(line.lower() for line in fork_job_lines)
    finalize_job_text = "\n".join(line.lower() for line in finalize_job_lines)

    for forbidden_fork_fragment in (
        "playwright baseline (fork fallback)",
        "npx playwright install --with-deps",
        "npm run test:e2e:baseline",
    ):
        if forbidden_fork_fragment in workflow_text.lower():
            raise OmarWorkflowContractError(
                f"fork fallback must not use browser baseline in place of deterministic no-secret checks: {forbidden_fork_fragment}"
            )

    _require(
        "persist-credentials: false" in fork_job_text,
        "fork static checkout must disable persisted credentials",
    )
    _require(
        "github.event.pull_request.head.repo.full_name" in fork_job_text
        and "github.event.pull_request.head.sha" in fork_job_text,
        "fork static checkout must read the untrusted pull request head explicitly",
    )
    _require(
        "run deterministic fork fallback checks" in fork_job_text,
        "fork static job must run deterministic fallback checks",
    )
    _require(
        "git ls-files" in fork_job_text and ".env" in fork_job_text,
        "fork static job must fail closed on tracked dotenv files",
    )
    _require(
        "needs: [omar-precheck, omar-review, omar-fork-static]" in finalize_job_text,
        "Omar Gate Finalize must depend on trusted and fork Omar jobs",
    )
    _require(
        "omar_review_result" in finalize_job_text
        and "omar_fork_static_result" in finalize_job_text,
        "Omar Gate Finalize must inspect trusted and fork job results",
    )
    _require(
        "::error::omar fork static result is" in finalize_job_text,
        "Omar Gate Finalize must fail closed when fork static checks fail",
    )
    _require(
        "::error::omar gate review result is" in finalize_job_text,
        "Omar Gate Finalize must fail closed when trusted Omar review fails",
    )

    forbidden_comment_fragments = (
        "wait_for_" + "authoritative" + "_omar_review.py",
        "sentinelayer-omar-" + "summary",
        "--summary-out",
        "--upsert" + "-comment",
    )
    for fragment in forbidden_comment_fragments:
        if fragment in workflow_text:
            raise OmarWorkflowContractError(
                f"omar-gate.yml must not require PR summary-comment evidence: {fragment}"
            )

    required_direct_fragments = (
        "Validate Omar workflow contract",
        "check_forbidden_omar_surface.py --self-test",
        "check_forbidden_omar_surface.py",
        "Validate Omar provider secrets",
        "OPENAI_API_KEY is required for repo-owned Omar LLM scans",
        "mrrCarter/sentinelayer-v1-action@8afb7dbb42a5e1c25233d422c4cabe401ba02380",
        "Omar Gate",
        "openai_api_key: ${{ secrets.OPENAI_API_KEY }}",
        "llm_provider: openai",
        "sentinelayer_managed_llm: ${{ secrets.SENTINELAYER_TOKEN != '' }}",
        "model: gpt-5.3-codex",
        "codex_model: gpt-5.3-codex",
        "model_fallback: gpt-5.3-codex",
        'use_codex: "true"',
        "llm_failure_policy: block",
        "Assert Omar LLM contract is active",
        "REQUESTED_LLM_PROVIDER: openai",
        "REQUESTED_MODEL: gpt-5.3-codex",
        "REQUESTED_CODEX_MODEL: gpt-5.3-codex",
        "REQUESTED_FALLBACK_MODEL: gpt-5.3-codex",
        'REQUESTED_USE_CODEX: "true"',
        "REQUESTED_FAILURE_POLICY: block",
        "Omar LLM contract active",
        "Omar Gate did not pass",
        "Resolve sanitized Omar artifact directory",
        'artifact_dir=".sentinelayer/runs/${normalized_run_id}"',
        "Upload Omar Gate artifacts",
        "actions/upload-artifact",
        "path: ${{ steps.artifact_path.outputs.artifact_dir }}",
        "Compute PR-scoped P2 count",
        "count_scoped_p2.py",
        "Enforce Omar reviewer merge thresholds",
        "WEB_PUSH_P2_MAX_ALLOWED",
        "Omar Gate merge threshold passed",
        "Emit Omar run summary",
        "merge_threshold",
        "Omar Gate Finalize",
        *TELEMETRY_LOG_DOWNLOAD_FRAGMENTS,
    )
    for fragment in required_direct_fragments:
        if fragment not in workflow_text:
            raise OmarWorkflowContractError(
                f"omar-gate.yml is missing direct Omar Gate evidence fragment: {fragment}"
            )

    _require(
        "--location-trusted" not in workflow_text,
        "telemetry job-log download must not forward authorization across origins",
    )


def _assert_fails(workflow_text: str) -> None:
    try:
        validate_omar_workflow_text(workflow_text)
    except OmarWorkflowContractError:
        return
    raise AssertionError("invalid Omar workflow should fail validation")


def _run_self_tests() -> None:
    valid = r"""
name: Omar Gate
permissions:
  contents: read
  id-token: write
jobs:
  omar-review:
    permissions:
      contents: read
      id-token: write
    steps:
      - name: Validate Omar workflow contract
        run: |
          python3 scripts/ci/check_omar_workflow_contract.py --self-test
          python3 scripts/ci/check_omar_workflow_contract.py
          python3 scripts/ci/check_forbidden_omar_surface.py --self-test
          python3 scripts/ci/check_forbidden_omar_surface.py
      - name: Validate Omar provider secrets
        run: |
          echo "SENTINELAYER_TOKEN is required for Omar Gate telemetry, artifacts, and PR checks."
          echo "OPENAI_API_KEY is required for repo-owned Omar LLM scans."
      - name: Omar Gate
        uses: mrrCarter/sentinelayer-v1-action@8afb7dbb42a5e1c25233d422c4cabe401ba02380
        with:
          openai_api_key: ${{ secrets.OPENAI_API_KEY }}
          llm_provider: openai
          sentinelayer_managed_llm: ${{ secrets.SENTINELAYER_TOKEN != '' }}
          model: gpt-5.3-codex
          codex_model: gpt-5.3-codex
          model_fallback: gpt-5.3-codex
          use_codex: "true"
          codex_only: "false"
          llm_failure_policy: block
      - name: Assert Omar LLM contract is active
        env:
          REQUESTED_LLM_PROVIDER: openai
          REQUESTED_MODEL: gpt-5.3-codex
          REQUESTED_CODEX_MODEL: gpt-5.3-codex
          REQUESTED_FALLBACK_MODEL: gpt-5.3-codex
          REQUESTED_USE_CODEX: "true"
          REQUESTED_FAILURE_POLICY: block
        run: |
          echo "Omar LLM contract active"
          echo "Omar Gate did not pass"
      - name: Resolve sanitized Omar artifact directory
        run: |
          artifact_dir=".sentinelayer/runs/${normalized_run_id}"
      - name: Upload Omar Gate artifacts
        uses: actions/upload-artifact@50769540e7f4bd5e21e526ee35c689e35e0d6874
        with:
          path: ${{ steps.artifact_path.outputs.artifact_dir }}
      - name: Compute PR-scoped P2 count
        run: python3 .github/scripts/count_scoped_p2.py
      - name: Enforce Omar reviewer merge thresholds
        env:
          WEB_PUSH_P2_MAX_ALLOWED: "40"
        run: echo "Omar Gate merge threshold passed"
      - name: Emit Omar run summary
        run: echo "merge_threshold"
      - name: Assert Omar telemetry uploads
        run: |
          curl --silent --show-error --location --fail-with-body \
            --proto-redir '=https' --max-redirs 3 \
            --header "Authorization: Bearer ${GH_TOKEN}" \
            --header "Accept: application/vnd.github+json" \
            --header "X-GitHub-Api-Version: 2026-03-10" \
            --output "${log_file}" \
            "https://api.github.com/repos/${REPOSITORY}/actions/jobs/${job_id}/logs"
  omar-fork-static:
    steps:
      - uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683
        with:
          repository: ${{ github.event.pull_request.head.repo.full_name }}
          ref: ${{ github.event.pull_request.head.sha }}
          persist-credentials: false
      - name: Run deterministic fork fallback checks
        run: |
          git ls-files | grep -E '(^|/)\.env(\..+)?$'
  omar-gate-finalize:
    name: Omar Gate Finalize
    needs: [omar-precheck, omar-review, omar-fork-static]
    steps:
      - name: Consolidate Omar gate status
        env:
          OMAR_REVIEW_RESULT: success
          OMAR_FORK_STATIC_RESULT: success
        run: |
          echo "::error::Omar fork static result is bad"
          echo "::error::Omar Gate review result is bad"
"""
    validate_omar_workflow_text(valid)

    # Job logs can contain ANSI bytes and must be read before the parent run is
    # complete. Replacing the bounded job endpoint with either incompatible CLI
    # transport, or dropping its auth header, must fail the workflow contract.
    _assert_fails(
        valid.replace(
            TELEMETRY_LOG_DOWNLOAD_FRAGMENTS[0],
            'gh run view "${RUN_ID}" --repo "${REPOSITORY}" --log',
            1,
        )
    )
    _assert_fails(
        valid.replace(TELEMETRY_LOG_DOWNLOAD_FRAGMENTS[2], "", 1)
    )
    _assert_fails(
        valid.replace(
            "--location --fail-with-body",
            "--location-trusted --fail-with-body",
            1,
        )
    )

    # Bridge/broken action pin plus bridge-only pr_number must be rejected.
    _assert_fails(
        """
name: Omar Gate
permissions:
  contents: read
  id-token: write
jobs:
  omar-review:
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: mrrCarter/sentinelayer-v1-action@721bc7efe1402fcce416becea3d247b838119ed2
        with:
          pr_number: 259
          sentinelayer_managed_llm: "true"
"""
    )

    # A literal managed_llm=true (phantom managed-only) instead of the
    # SENTINELAYER_TOKEN-gated expression must be rejected.
    _assert_fails(
        """
name: Omar Gate
permissions:
  contents: read
  id-token: write
jobs:
  omar-review:
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: mrrCarter/sentinelayer-v1-action@8afb7dbb42a5e1c25233d422c4cabe401ba02380
        with:
          openai_api_key: ${{ secrets.OPENAI_API_KEY }}
          llm_provider: openai
          sentinelayer_managed_llm: "true"
          model: gpt-5.3-codex
          codex_model: gpt-5.3-codex
          model_fallback: gpt-5.3-codex
          use_codex: "true"
"""
    )

    # Provider drift away from the pinned openai path must be rejected.
    _assert_fails(
        """
name: Omar Gate
permissions:
  contents: read
  id-token: write
jobs:
  omar-review:
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: mrrCarter/sentinelayer-v1-action@8afb7dbb42a5e1c25233d422c4cabe401ba02380
        with:
          openai_api_key: ${{ secrets.OPENAI_API_KEY }}
          llm_provider: anthropic
          sentinelayer_managed_llm: ${{ secrets.SENTINELAYER_TOKEN != '' }}
          model: gpt-5.3-codex
          codex_model: gpt-5.3-codex
          model_fallback: gpt-5.3-codex
          use_codex: "true"
"""
    )

    # Model drift away from the pinned deterministic codex model must be
    # rejected (exercises the per-line model pin).
    _assert_fails(
        """
name: Omar Gate
permissions:
  contents: read
  id-token: write
jobs:
  omar-review:
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: mrrCarter/sentinelayer-v1-action@8afb7dbb42a5e1c25233d422c4cabe401ba02380
        with:
          openai_api_key: ${{ secrets.OPENAI_API_KEY }}
          llm_provider: openai
          sentinelayer_managed_llm: ${{ secrets.SENTINELAYER_TOKEN != '' }}
          model: gpt-4o
          codex_model: gpt-5.3-codex
          model_fallback: gpt-5.3-codex
          use_codex: "true"
"""
    )

    # Any non-OpenAI provider-key input must be rejected on the codex path.
    _assert_fails(
        """
name: Omar Gate
permissions:
  contents: read
  id-token: write
jobs:
  omar-review:
    permissions:
      contents: read
      id-token: write
    steps:
      - uses: mrrCarter/sentinelayer-v1-action@8afb7dbb42a5e1c25233d422c4cabe401ba02380
        with:
          openai_api_key: ${{ secrets.OPENAI_API_KEY }}
          google_api_key: ${{ secrets.GOOGLE_API_KEY }}
          xai_api_key: ${{ secrets.XAI_API_KEY }}
          llm_provider: openai
          sentinelayer_managed_llm: ${{ secrets.SENTINELAYER_TOKEN != '' }}
          model: gpt-5.3-codex
          codex_model: gpt-5.3-codex
          model_fallback: gpt-5.3-codex
          use_codex: "true"
"""
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Verify the senti-pocket Omar Gate workflow pins the deterministic repo-owned codex LLM contract."
    )
    parser.add_argument(
        "--workflow",
        default=".github/workflows/omar-gate.yml",
        help="Path to the Omar Gate workflow.",
    )
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)

    if args.self_test:
        _run_self_tests()

    workflow_path = Path(args.workflow)
    try:
        validate_omar_workflow_text(workflow_path.read_text(encoding="utf-8"))
    except OmarWorkflowContractError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
