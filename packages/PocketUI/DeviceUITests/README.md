# PocketUI device UI tests

Atlas owns `apps/SentiPocketApp` and its XcodeGen manifest, so Pulse does not add an app UI-test target.
During integration, Atlas should:

1. Add `PocketUIDeviceFlowTests.swift` to an iOS UI-testing target that depends on `PocketUI`.
2. Map `-PocketUITestScenario` to deterministic states named `inbox`, `incoming`, `conversation`, `proposal`,
   `evidence`, `offline-pending`, `verified-action-receipt`, `invalid-checkpoint`, `invalid-conversation`,
   `invalid-receipt`, `reconnecting-proposal`, `long-inbox-error`, and `long-invalid-conversation`. The two long
   failure scenarios must supply multi-paragraph error/reason text. The invalid conversation scenarios must carry invalid bundle
   integrity even if its transcript and voice state are populated, proving the UI does not expose them. Successful
   checkpoint scenarios must use a genuinely verified deterministic test bundle, not relabel the unsigned fixture.
   The verified receipt scenario remains blocked until Atlas publishes the non-forgeable receipt trust-anchor
   contract: the current production `ReceiptTrustStore` is intentionally empty/fail-closed. Once that contract lands,
   sign the canonical receipt with a deterministic test key, inject only its pinned public test anchor, and expose
   action ID `action-device-1` targeting sequence `230180`; a placeholder signature is not acceptable.
3. Make the proposal scenario synchronously reduce the read-back intent to an exact completed read-back;
   it must not call a real Senti write.
4. Bundle `PocketContracts/Fixtures/canonical_checkpoint.json` into the app target so package previews and
   device scenarios decode the single canonical fixture rather than copying its values.
5. Run the UI target on the target iPhone and an iPhone simulator at default and accessibility XXXL sizes,
   including the iOS 17+ system accessibility audit.
6. The host recording coordinator must independently stop capture for `AVAudioSession` interruption, route-change,
   cancellation, scene-background, and teardown callbacks. The SwiftUI control provides an idempotent lifecycle stop,
   but it does not own or prove audio-session cleanup.

This is unexecuted device-test source authored on Windows. It is not a configured XCUITest target and is not
evidence of a passing compile, simulator run, physical-device run, accessibility audit, or audio interruption test.
Those claims require Atlas's target wiring plus the exact Xcode result and destination.
