# Omar Gate — Senti Pocket

Set up the **same way as the SentinelLayer org repos**: `.github/workflows/omar-gate.yml` calls the reusable `mrrCarter/sentinelayer-v1-action` (pinned SHA `c61fb388…`), which delegates a **real-LLM deep scan** to the Sentinelayer backend and posts a PR review + a required `Omar Gate` check.

## Configuration (matches the org default)
- **Model:** `gpt-5.3-codex` (codex 5.3) — `use_codex: true`, `model_fallback: gemini-2.5-flash`
- **Managed LLM:** `sentinelayer_managed_llm: true` (backend adjudication)
- **Scan mode:** `deep` · **Severity gate:** `P1` (P1+ findings block merge)
- **Failure policy:** `block` (fail-closed — if adjudication can't complete, the gate blocks; it does not silently pass)
- **Fork PRs:** privileged scan skipped (precheck guard)

## Activation — NOT yet live. Three gates, all owner actions:
1. **GitHub Actions billing.** Actions is account-suspended (billing lapse, 2026-07-17). The workflow will not execute on any repo under this account until billing is restored. Until then Omar is **dormant**.
2. **Repo secret `SENTINELAYER_TOKEN`.** Required to authorize the scan. Add in `Settings → Secrets and variables → Actions` (same token the org repos use). Optional provider fallbacks: `OPENAI_API_KEY`, `GOOGLE_GEMINI_API_KEY`. Optional var `SENTINELAYER_SPEC_ID` to bind a spec-governance context. The backend must also recognize `mrrCarter/senti-pocket` for `managed_llm:invoke` (it's a new repo — confirm the Omar backend authorizes it).
3. **Branch protection (required check).** Making `Omar Gate` a *required* status check needs **GitHub Pro** or a **public** repo — the branch-protection API currently returns `403 Upgrade to GitHub Pro or make this repository public` on this private/free combo. Until then the check runs but cannot be hard-required by GitHub.

## Interim posture
Until Omar is live, **claude-warden is the enforcing gate**: no merge to the demo branch without a warden audit vs `SWE_excellence_framework` + a security scan + a second distinct-role sign-off. CI/billing being down does not lower the bar.

## Known operational risk (from org experience)
Fail-closed + all providers dry ⇒ the gate can self-DoS merges during a provider-capacity outage. The org repos add a deterministic break-glass fallback lane (needs a `scripts/ci/classify_omar_provider_outage.py` classifier). Port that here if/when Pocket depends on Omar for release velocity.
