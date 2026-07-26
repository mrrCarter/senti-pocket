import importlib.util
from pathlib import Path


SCRIPT = Path(__file__).with_name("validate_omar_managed_llm_contract.py")
spec = importlib.util.spec_from_file_location("validate_omar_managed_llm_contract", SCRIPT)
assert spec is not None
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


VALID_WORKFLOW = """
- name: Run Omar Gate
  uses: mrrCarter/sentinelayer-v1-action@4cb3063e04e3b899981b25f6918b26f70d35a8d4
  with:
    sentinelayer_managed_llm: "true"
    llm_failure_policy: block
- name: Assert Omar LLM model contract is active
  env:
    REQUESTED_MANAGED_LLM: "true"
"""


def test_managed_llm_contract_accepts_current_shape() -> None:
    assert module.validate_workflow_text(VALID_WORKFLOW) == []


def test_managed_llm_contract_rejects_local_only_bridge() -> None:
    errors = module.validate_workflow_text(
        VALID_WORKFLOW.replace('sentinelayer_managed_llm: "true"', 'sentinelayer_managed_llm: "false"')
    )

    assert any("sentinelayer_managed_llm: false" in error for error in errors)


def test_managed_llm_contract_rejects_legacy_llm_inputs() -> None:
    errors = module.validate_workflow_text(f"{VALID_WORKFLOW}\n    openai_api_key: ${{{{ secrets.OPENAI_API_KEY }}}}\n")

    assert any("legacy BYOK inputs" in error for error in errors)
