# Demo assets — the tamper→refuse money-shot

`canonical_checkpoint.tampered.json` is the signed demo checkpoint with **one signature
byte flipped**. It is the exact input that drives the phone's fail-closed refusal state.

PROVEN (Node ed25519, pinned anchor `pocket-demo-app-fixture`):
- the REAL fixture (`apps/SentiPocketApp/Resources/canonical_checkpoint.json`) verifies **TRUE**
- this tampered variant verifies **FALSE** → `VerifiedBundle.verify` returns nil → `SentiPocketApp`
  renders the refusal state instead of the briefing.

To demo the refusal: swap this file in for `Resources/canonical_checkpoint.json` and rebuild
(or load it via a debug toggle). The briefing never renders on unverified data — that is the wedge.
