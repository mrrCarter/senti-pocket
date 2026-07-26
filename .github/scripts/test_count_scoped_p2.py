import importlib.util
from pathlib import Path


SCRIPT = Path(__file__).with_name("count_scoped_p2.py")
spec = importlib.util.spec_from_file_location("count_scoped_p2", SCRIPT)
assert spec is not None
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


def test_count_scoped_p2_uses_unique_top_findings_only() -> None:
    comment = """
## Omar Gate

### Top Findings

1. **P2** [`.github/workflows/request-demo-intake-smoke.yml:1`](https://example.test) - cicd
2. **P2** [`apps/api/app/schemas/contact.py:27`](https://example.test) - security
3. **P2** [`apps/web/app/consumer/signup/page.tsx:19`](https://example.test) - security

### Reviewer Brief

1. **P2** `.github/workflows/request-demo-intake-smoke.yml:1` - cicd
2. **P2** `apps/api/app/schemas/contact.py:27` - security
"""
    changed = {
        ".github/workflows/request-demo-intake-smoke.yml",
        "apps/api/app/schemas/contact.py",
    }

    assert module.count_scoped_p2(comment, changed) == 2


def test_count_scoped_p2_counts_distinct_findings_in_same_file() -> None:
    comment = """
### Top Findings

1. **P2** [`apps/api/app/schemas/contact.py:27`](https://example.test) - security
2. **P2** [`apps/api/app/schemas/contact.py:81`](https://example.test) - security
"""

    assert module.count_scoped_p2(comment, {"apps/api/app/schemas/contact.py"}) == 2
