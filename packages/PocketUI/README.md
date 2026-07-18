# PocketUI

Pulse-owned SwiftUI product surfaces for Senti Pocket. The package consumes `PocketContracts` v0.1.8 at
`7e1cfbe` and
contains no voice, model, sync, credential, MCP, or writeback client.

## Integration boundary

Atlas supplies one immutable `PocketUIState` and handles typed `PocketUIIntent` values:

```swift
PocketRootView(state: coordinator.uiState) { intent in
    coordinator.handle(intent)
}
```

Atlas's `@MainActor` coordinator owns navigation and async dependencies. PocketUI never infers a successful
write from reachability or queue insertion.

Atlas owns one long-lived `ProposalConfirmationLedger` and injects it into every gate. This in-memory ledger is only
UI defense-in-depth; it is not crash-safe authority. The deterministic coordinator must atomically persist the
immutable signed authorization envelope and reserve its single-use ticket before any intent can reach a write path.
Validation uses `ProposalValidationState.authorize(_:context:)`, but the current v0.1.8 adapter context initializer is
module-internal. Production confirmation therefore remains fail-closed until Atlas publishes the frozen full-auth
grant that binds the expected session, sequence, proposal commitment, AIdenID subject/device, authorization mode,
freshness, and single-use ticket. Never recreate the ledger during navigation or app-state reconstruction.

The confirm button atomically consumes that shared ledger and emits only a gate-minted capability:

```swift
case .confirmProposal(let confirmation):
    guard authoritativeGate.markSubmitting(confirmation, at: clock.now) else { return }
    // Publish disabled state before awaiting.
    // Map only this minted intent to PocketCall.ConfirmationCapability.forReadBack(
    //     of: confirmation.proposal,
    //     challenge: confirmation.confirmationChallenge
    // ). Never mint the public PocketCall capability from another UI/coordinator path.
    // Pass `confirmation` to deterministic governed code. Relay revalidates authorization, hash, and idempotency.
```

`ActionConfirmationIntent` has no public initializer. Copied or reconstructed gates sharing the ledger cannot mint
a second capability for the same proposal ID/hash in one process. That does not replace the coordinator's atomic
persist/reserve transaction or the gateway's authoritative freshness, authorization, and replay checks.

Read-back follows the same exact snapshot:

1. On `.requestProposalReadBack`, call `beginReadBack(for:at:)` and retain its returned attempt.
2. Speak `attempt.payload`, including its verbatim `fullMessageText`.
3. Call `completeReadBack(_:for:at:)` with that same attempt only after the exact snapshot finishes.
4. Any proposal field change creates a new gate and requires a new read-back.

Overlapping starts are rejected, and stale completion/failure callbacks cannot arm a newer attempt.

`ReceiptPresentation.evaluate` is fail-closed. `posted` requires a concrete v0.1.8 `ActionResultRef`, execution
timestamp, matching proposal/session/hash, a matching key ID from Atlas's trusted gateway keyring, and successful
Ed25519 verification of the exact receipt payload. A threaded reply is accepted only as an action reference whose
target sequence matches the confirmed proposal; it is never displayed as a fabricated resulting sequence. It does
not accept a caller-asserted `SignatureState`. The public v0.1.8 `ReceiptTrustStore` can currently be constructed only
empty, so production posted receipts remain invalid until Atlas publishes a non-forgeable pinned trust-anchor type.
Pending connectivity and reconnecting writes render **not sent**; the wire receipt alone does not prove that a
durable queue record exists.

## Evidence and fixture

The package depends on both `PocketContracts` and PocketCall's non-forgeable `VerifiedBundle`. The unit test decodes
`../PocketContracts/Fixtures/canonical_checkpoint.json` directly with ISO-8601 dates;
the fixture is not copied. The fixture's `FIXTURE_UNSIGNED` signature must be injected as `.unverified`, never
`.verified`; `.unverified` is fail-closed for opening, displaying, narrating, and answering checkpoint content.
The unsigned canonical previews therefore exercise the integrity-blocked UI until Atlas supplies a genuinely
verified bundle through the v0.1.8 ingest seam. Bundle and evidence previews decode that JSON. Atlas's typed `PocketFixtures` supplies separate
briefing, Q&A, proposal, pending-receipt, and placeholder-posted-receipt scenarios; Pulse does not assume those
typed scenarios are value-identical to the canonical bundle.

Evidence presentation uses `PresentedEvidenceSelection`, minted only from the current `VerifiedBundle`. The open
intent carries that selection rather than a raw `EvidenceRef`, and the sheet re-resolves it only while the complete
verified bundle remains identical; navigation, integrity failure, bundle mutation, ambiguous evidence IDs, or
caller-supplied replacement content dismisses/fails closed.

## Draft integration holds

This package is a reviewable UI draft, not merge-ready write authority. The v0.1.8 contracts at `7e1cfbe` still
leave the confirmation capability publicly constructible, make single-use a coordinator convention, reduce
`createdAt` identity to epoch milliseconds, and do not bind a receipt's result kind/action target to the confirmed
proposal in `PocketCall.receiptBinds`. PocketUI's ledger, full-`Date` comparison, and receipt validation are
defense-in-depth; they cannot replace deterministic contract enforcement. The Carter decision is FULL
human/device authorization; the commitment-based capability, server-derived AIdenID subject, Secure Enclave key,
fresh `LAContext` signature operation, separate App Attest enrollment, and tagged online-token/offline-ticket modes
must be integrated only after Atlas publishes the frozen contract. The v0.1.8 adapter cannot be constructed by a
production caller and its raw challenge must not be logged, spoken, previewed, or persisted by the host.

The current AIdenID service does not expose the registered native-client Authorization Code + PKCE surface assumed
by the full-auth design. Do not expose its opaque `ConsumerSession` cookie to Pocket and do not reinterpret the
agent/service exchange as human authority. Native login, server-derived human subject, key binding, refresh/reuse
detection, revocation, and redirect/state/nonce KAVs remain a separate fail-closed prerequisite.

Bundle content also remains fail-closed until Relay and Atlas provide a key-ID-matched verified bundle under the
pinned gateway keyring. A Mac compile/test pass, app-host wiring, simulator/device UI tests, VoiceOver audit, and
signed-receipt end-to-end run remain required before merge.

## Validation

On a Mac:

```bash
cd packages/PocketUI
swift test
```

Device UI-test source and Atlas integration steps are in `DeviceUITests/`. Windows has no Swift/Xcode toolchain,
so authoring and static checks here are not compile, preview, simulator, VoiceOver, or physical-device proof.
