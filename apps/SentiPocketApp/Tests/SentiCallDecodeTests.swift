#if canImport(CallKit) && canImport(PushKit)
import XCTest
import CallKit
import AVFoundation
@testable import SentiPocketApp

/// Locks SentiCallManager's decode (CallKit-ring DISPLAY) + receiveState (the DialReceiveState surfaced at push-receive).
/// The push fields are display-only — none drive the governed write (that's the hydrated ring via DialCoordinator).
@MainActor
final class SentiCallDecodeTests: XCTestCase {   // SentiCallManager is @MainActor, so its static decode()/receiveState() are too

    // MARK: - decode display (part-b minor)

    func test_decode_prefers_callerName_over_who() {
        let call = SentiCallManager.decode([
            "id": "dial_1", "callerName": "claude-warden needs your decision", "who": "senti-pocket",
            "message": "", "priority": "high"
        ])
        XCTAssertEqual(call.dialId, "dial_1")
        XCTAssertEqual(call.callerDisplayName, "claude-warden needs your decision")
        XCTAssertEqual(call.priority, "high")
        XCTAssertEqual(call.message, "")   // a LEAN write-kind carries no push message
    }

    func test_decode_falls_back_who_then_default() {
        let noName = SentiCallManager.decode(["id": "dial_2", "who": "senti-pocket", "message": "", "priority": "low"])
        XCTAssertEqual(noName.callerDisplayName, "senti-pocket")
        let bare = SentiCallManager.decode(["id": "dial_3", "message": "", "priority": "medium"])
        XCTAssertEqual(bare.callerDisplayName, "Senti — decision needed")
    }

    func test_decode_invalid_priority_defaults_medium() {
        let call = SentiCallManager.decode(["id": "dial_4", "callerName": "Senti", "message": "", "priority": "BOGUS"])
        XCTAssertEqual(call.priority, "medium")
    }

    // MARK: - receiveState: the ENVELOPED device round-trip (part-b criterion #6, relay's shared fixture)

    /// Walk up from this source file to relay's committed gateway fixtures (zero-copy, single source of truth).
    private func loadFixture(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("services/pocket-gateway/test/fixtures/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                let data = try Data(contentsOf: candidate)
                return try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            }
            dir.deleteLastPathComponent()
        }
        XCTFail("fixture \(name) not found walking up from \(file) — needs relay's committed gateway fixture", file: file, line: line)
        return [:]
    }

    /// POSITIVE (test b): the deploy wraps the BARE buildDialPayload DTO as { aps, ...dial-fields-TOP-LEVEL }. For every
    /// #96 KAV case, receiveState must serialize + decode that envelope → dialId == payload.id and state == (fetch ?
    /// .needsHydration : .renderable). Covers rich_info (fetch=false → .renderable), which the inline LEAN test did not.
    func test_receiveState_enveloped_roundtrip_covers_all_KAV_cases() throws {
        let env = try loadFixture("dial-push-envelope-v1.json")
        let src = try loadFixture("dial-payload-v1.json")
        guard let aps = env["apsEnvelope"] as? [String: Any] else { return XCTFail("envelope fixture missing apsEnvelope") }
        guard let cases = src["cases"] as? [String: Any], !cases.isEmpty else { return XCTFail("source KAV cases missing") }
        for (name, raw) in cases {
            guard let c = raw as? [String: Any], let payload = c["payload"] as? [String: Any] else {
                return XCTFail("case \(name): missing payload")
            }
            var enveloped: [AnyHashable: Any] = payload   // dial fields spread TOP-LEVEL...
            enveloped["aps"] = aps                         // ...alongside the aps envelope (the real device shape)
            guard let (state, dialId) = SentiCallManager.receiveState(from: enveloped) else {
                return XCTFail("case \(name): enveloped push should decode")
            }
            XCTAssertEqual(dialId, payload["id"] as? String, "case \(name): dialId")
            let fetch = (payload["fetch"] as? Bool) ?? false
            if fetch {
                guard case .needsHydration = state else { return XCTFail("case \(name): fetch=true must be .needsHydration, got \(state)") }
            } else {
                guard case .renderable = state else { return XCTFail("case \(name): fetch=false must be .renderable, got \(state)") }
            }
        }
    }

    /// NEGATIVE (test b): nesting the DTO under a wrong-placement key ({aps, payload:<DTO>}) → top-level id absent →
    /// nil (no ring stored). The naive apnsSend that nests under the field literally named `payload` would silently
    /// drop EVERY ring in production — this catches it. Keys single-sourced from the fixture's wrongPlacementKeys.
    func test_receiveState_nil_when_dto_nested_under_wrong_key() throws {
        let env = try loadFixture("dial-push-envelope-v1.json")
        let src = try loadFixture("dial-payload-v1.json")
        guard let aps = env["apsEnvelope"] as? [String: Any],
              let wrongKeys = env["wrongPlacementKeys"] as? [String],
              let anyCase = (src["cases"] as? [String: Any])?.values.first as? [String: Any],
              let payload = anyCase["payload"] as? [String: Any] else { return XCTFail("fixtures missing fields") }
        XCTAssertFalse(wrongKeys.isEmpty)
        for k in wrongKeys {
            let nested: [AnyHashable: Any] = ["aps": aps, k: payload]
            XCTAssertNil(SentiCallManager.receiveState(from: nested), "nesting under \(k) must yield nil (no top-level id)")
        }
    }

    // THROW-GUARD (warden #5b; atlas + relay independently): data(withJSONObject:) raises an NSException — NOT a Swift
    // error, so try? would NOT catch it → CRASH on a malformed push. isValidJSONObject guards it to the fail-safe nil.
    func test_receiveState_nil_on_nonconforming_dict_no_crash() {
        let bad: [AnyHashable: Any] = ["id": "dial_x", "createdAt": Date()]  // Date is not JSON-serializable
        XCTAssertNil(SentiCallManager.receiveState(from: bad))               // fail-safe nil, NEVER a crash
    }

    func test_unselected_push_is_redacted_and_not_retained_for_answer() throws {
        let source = try loadFixture("dial-payload-v1.json")
        guard let cases = source["cases"] as? [String: Any],
              let raw = cases.values.first as? [String: Any],
              let payload = raw["payload"] as? [String: Any] else {
            return XCTFail("source fixture missing a payload")
        }

        let prepared = SentiCallManager.prepareIncomingPush(
            payload,
            isDialAuthorized: { _ in false }
        )

        XCTAssertEqual(prepared.call.callerDisplayName, "Senti")
        XCTAssertEqual(prepared.call.message, "")
        XCTAssertNil(prepared.call.context)
        XCTAssertEqual(prepared.call.priority, "medium")
        XCTAssertNil(prepared.state, "an old registration must not arm hydration after selection/sign-out revocation")
        XCTAssertNil(prepared.dialId)
    }

    func test_selected_push_keeps_display_and_receive_state() throws {
        let source = try loadFixture("dial-payload-v1.json")
        guard let cases = source["cases"] as? [String: Any],
              let raw = cases.values.first as? [String: Any],
              let payload = raw["payload"] as? [String: Any],
              let sessionId = payload["sessionId"] as? String else {
            return XCTFail("source fixture missing a session payload")
        }

        let prepared = SentiCallManager.prepareIncomingPush(
            payload,
            isDialAuthorized: { $0.sessionId == sessionId }
        )

        XCTAssertNotNil(prepared.state)
        XCTAssertEqual(prepared.dialId, payload["id"] as? String)
        XCTAssertEqual(prepared.call.dialId, payload["id"] as? String)
    }

    func test_real_binding_gate_rejects_legacy_and_stale_revision_but_accepts_exact_v2_proof() throws {
        let source = try loadFixture("dial-payload-v1.json")
        guard let cases = source["cases"] as? [String: Any],
              let raw = cases.values.first as? [String: Any],
              var payload = raw["payload"] as? [String: Any],
              let sessionId = payload["sessionId"] as? String else {
            return XCTFail("source fixture missing a session payload")
        }
        let binding = DeviceRingBinding(
            registryVersion: 2,
            sessionId: sessionId,
            tokenFingerprint: "fingerprint",
            installationGeneration: "9",
            bindingId: String(repeating: "i", count: 24),
            bindingRevision: String(repeating: "r", count: 32),
            leaseExpiresAtSec: 2_000
        )
        let gate = DeviceRingBindingGate(initialBinding: binding, nowEpochSec: { 1_000 })
        let authorize: (RingCore) -> Bool = { core in
            gate.permits(
                sessionId: core.sessionId,
                bindingVersion: core.bindingVersion,
                bindingId: core.bindingId,
                bindingRevision: core.bindingRevision,
                installationGeneration: core.installationGeneration
            )
        }

        let legacy = SentiCallManager.prepareIncomingPush(payload, isDialAuthorized: authorize)
        XCTAssertNil(legacy.state, "new app must not accept an unversioned V1 push as current V2 authority")

        payload["bindingVersion"] = 2
        payload["bindingId"] = binding.bindingId
        payload["bindingRevision"] = "stale-revision"
        payload["installationGeneration"] = binding.installationGeneration
        let stale = SentiCallManager.prepareIncomingPush(payload, isDialAuthorized: authorize)
        XCTAssertNil(stale.state)
        XCTAssertEqual(stale.call.callerDisplayName, "Senti")

        payload["bindingRevision"] = binding.bindingRevision
        let exact = SentiCallManager.prepareIncomingPush(payload, isDialAuthorized: authorize)
        XCTAssertNotNil(exact.state)
        XCTAssertEqual(exact.dialId, payload["id"] as? String)
    }

    func test_partial_v2_proof_is_rejected_before_authorization() throws {
        let source = try loadFixture("dial-payload-v1.json")
        guard let cases = source["cases"] as? [String: Any],
              let raw = cases.values.first as? [String: Any],
              var payload = raw["payload"] as? [String: Any] else {
            return XCTFail("source fixture missing a payload")
        }
        payload["bindingVersion"] = 2
        payload["bindingId"] = String(repeating: "i", count: 24)

        guard let received = SentiCallManager.receiveState(from: payload) else {
            return XCTFail("top-level id remains decodable")
        }
        guard case .rejected(let reason) = received.state else {
            return XCTFail("a partial V2 tuple must reject, never downgrade")
        }
        XCTAssertTrue(reason.contains("binding proof"))
    }

    func test_push_completion_and_hydration_wait_for_successful_callkit_report() async throws {
        let source = try loadFixture("dial-payload-v1.json")
        guard let cases = source["cases"] as? [String: Any],
              let raw = cases.values.first as? [String: Any],
              let payload = raw["payload"] as? [String: Any] else {
            return XCTFail("source fixture missing a payload")
        }
        let provider = CXProvider(configuration: CXProviderConfiguration())
        var reportCallback: (@MainActor @Sendable (Bool) -> Void)?
        let manager = SentiCallManager(
            provider: provider,
            reportIncomingCall: { _, _, completion in reportCallback = completion }
        )
        manager.isIncomingDialAuthorized = { _ in true }
        var received: [(String, UUID)] = []
        manager.onDialReceived = { _, dialId, callUUID in received.append((dialId, callUUID)) }
        var pushCompletionCount = 0

        manager.handleIncomingPushPayload(payload) { pushCompletionCount += 1 }

        XCTAssertEqual(pushCompletionCount, 0)
        XCTAssertTrue(received.isEmpty, "protected hydration state must wait for CallKit acceptance")
        reportCallback?(true)
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(pushCompletionCount, 1)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.first?.0, payload["id"] as? String)

        reportCallback?(true)
        for _ in 0..<3 { await Task.yield() }
        XCTAssertEqual(pushCompletionCount, 1, "a hostile duplicate report callback cannot complete PushKit twice")
        XCTAssertEqual(received.count, 1)
    }

    func test_failed_callkit_report_completes_push_once_without_retaining_hydration() async throws {
        let source = try loadFixture("dial-payload-v1.json")
        guard let cases = source["cases"] as? [String: Any],
              let raw = cases.values.first as? [String: Any],
              let payload = raw["payload"] as? [String: Any] else {
            return XCTFail("source fixture missing a payload")
        }
        let provider = CXProvider(configuration: CXProviderConfiguration())
        var reportCallback: (@MainActor @Sendable (Bool) -> Void)?
        let manager = SentiCallManager(
            provider: provider,
            reportIncomingCall: { _, _, completion in reportCallback = completion }
        )
        manager.isIncomingDialAuthorized = { _ in true }
        var receivedCount = 0
        manager.onDialReceived = { _, _, _ in receivedCount += 1 }
        var pushCompletionCount = 0

        manager.handleIncomingPushPayload(payload) { pushCompletionCount += 1 }
        reportCallback?(false)
        for _ in 0..<3 { await Task.yield() }

        XCTAssertEqual(pushCompletionCount, 1)
        XCTAssertEqual(receivedCount, 0)
    }

    func test_revoke_during_report_tombstones_late_success_and_never_resurrects_state() async throws {
        let source = try loadFixture("dial-payload-v1.json")
        guard let cases = source["cases"] as? [String: Any],
              let raw = cases.values.first as? [String: Any],
              let payload = raw["payload"] as? [String: Any] else {
            return XCTFail("source fixture missing a payload")
        }
        let provider = CXProvider(configuration: CXProviderConfiguration())
        var reportCallback: (@MainActor @Sendable (Bool) -> Void)?
        var reportedEnds: [UUID] = []
        let manager = SentiCallManager(
            provider: provider,
            reportIncomingCall: { _, _, completion in reportCallback = completion },
            reportEndedCall: { reportedEnds.append($0) }
        )
        manager.isIncomingDialAuthorized = { _ in true }
        var receivedCount = 0
        manager.onDialReceived = { _, _, _ in receivedCount += 1 }
        var pushCompletionCount = 0

        manager.handleIncomingPushPayload(payload) { pushCompletionCount += 1 }
        manager.revokeAllCalls()
        reportCallback?(true)
        for _ in 0..<3 { await Task.yield() }

        XCTAssertEqual(pushCompletionCount, 1)
        XCTAssertEqual(receivedCount, 0)
        XCTAssertEqual(reportedEnds.count, 1, "late CallKit success must be ended after authority was revoked")
    }

    func test_revoke_all_calls_ends_a_still_ringing_call_and_notifies_host() {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        var reportedEnds: [UUID] = []
        let manager = SentiCallManager(
            provider: provider,
            reportEndedCall: { reportedEnds.append($0) }
        )
        var hostCancellations: [UUID] = []
        manager.onEnded = { hostCancellations.append($0) }
        let call = IncomingDecisionCall(
            id: UUID(),
            dialId: "dial-ringing",
            callerDisplayName: "Sensitive caller",
            message: "Sensitive decision",
            context: "Sensitive context",
            priority: "high"
        )
        manager.ring(call)

        manager.revokeAllCalls()
        manager.end(call.id)

        XCTAssertEqual(hostCancellations, [call.id])
        XCTAssertEqual(reportedEnds, [call.id], "deferred cleanup after revoke must not report the UUID twice")
    }

    func test_provider_reset_notifies_host_for_every_active_call_once() {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        let manager = SentiCallManager(provider: provider)
        var hostCancellations: [UUID] = []
        manager.onEnded = { hostCancellations.append($0) }
        let call = IncomingDecisionCall(
            id: UUID(),
            dialId: "dial-answered",
            callerDisplayName: "Senti",
            message: "",
            context: nil,
            priority: "medium"
        )
        manager.ring(call)

        manager.providerDidReset(provider)
        manager.providerDidReset(provider)

        XCTAssertEqual(hostCancellations, [call.id],
                       "provider reset must cancel the host flow, and a second reset must not duplicate it")
    }

    func test_late_deactivation_is_attributed_to_ended_call_not_the_next_answer() {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        let manager = SentiCallManager(provider: provider)
        let first = IncomingDecisionCall(
            id: UUID(), dialId: "dial-first", callerDisplayName: "Senti", message: "", context: nil, priority: "high"
        )
        let second = IncomingDecisionCall(
            id: UUID(), dialId: "dial-second", callerDisplayName: "Senti", message: "", context: nil, priority: "high"
        )
        let third = IncomingDecisionCall(
            id: UUID(), dialId: "dial-third", callerDisplayName: "Senti", message: "", context: nil, priority: "high"
        )
        var activations: [UUID] = []
        var deactivations: [UUID] = []
        var hostEnds: [UUID] = []
        manager.onAudioSessionActivated = { _, id in activations.append(id) }
        manager.onAudioSessionDeactivated = { _, id in deactivations.append(id) }
        manager.onEnded = { hostEnds.append($0) }

        manager.ring(first)
        manager.provider(provider, perform: CXAnswerCallAction(call: first.id))
        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())
        manager.end(first.id)

        manager.ring(second)
        manager.provider(provider, perform: CXAnswerCallAction(call: second.id))
        manager.provider(provider, didDeactivate: AVAudioSession.sharedInstance())

        XCTAssertEqual(activations, [first.id])
        XCTAssertEqual(deactivations, [first.id], "call A's late deactivation must stay attributed to call A")
        XCTAssertEqual(hostEnds, [second.id], "call B must fail closed while call A owns the audio callback slot")

        manager.ring(third)
        manager.provider(provider, perform: CXAnswerCallAction(call: third.id))
        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(activations, [first.id, third.id], "consuming call A's tombstone must let a fresh call activate")
    }

    func test_provider_reset_releases_callkit_audio_ownership_without_didDeactivate() {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        let manager = SentiCallManager(provider: provider)
        let call = IncomingDecisionCall(
            id: UUID(), dialId: "dial-reset", callerDisplayName: "Senti", message: "", context: nil, priority: "high"
        )
        var deactivations: [UUID] = []
        manager.onAudioSessionDeactivated = { _, id in deactivations.append(id) }

        manager.ring(call)
        manager.provider(provider, perform: CXAnswerCallAction(call: call.id))
        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())
        manager.providerDidReset(provider)
        manager.providerDidReset(provider)

        XCTAssertEqual(deactivations, [call.id], "provider reset must release shared audio ownership exactly once")
    }

    func test_answer_activation_deadline_ends_a_wedged_episode_once() {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        var reportedEnds: [UUID] = []
        let manager = SentiCallManager(
            provider: provider,
            reportEndedCall: { reportedEnds.append($0) },
            audioActivationTimeoutNanoseconds: 60_000_000_000
        )
        let call = IncomingDecisionCall(
            id: UUID(), dialId: "dial-timeout", callerDisplayName: "Senti", message: "", context: nil, priority: "high"
        )
        let blocked = IncomingDecisionCall(
            id: UUID(), dialId: "dial-blocked", callerDisplayName: "Senti", message: "", context: nil, priority: "high"
        )
        let fresh = IncomingDecisionCall(
            id: UUID(), dialId: "dial-fresh", callerDisplayName: "Senti", message: "", context: nil, priority: "high"
        )
        var hostEnds: [UUID] = []
        var activations: [UUID] = []
        var deactivations: [UUID] = []
        manager.onEnded = { hostEnds.append($0) }
        manager.onAudioSessionActivated = { _, id in activations.append(id) }
        manager.onAudioSessionDeactivated = { _, id in deactivations.append(id) }

        manager.ring(call)
        manager.provider(provider, perform: CXAnswerCallAction(call: call.id))
        manager.expireAudioActivation(callUUID: call.id)
        manager.expireAudioActivation(callUUID: call.id)
        manager.ring(blocked)
        manager.provider(provider, perform: CXAnswerCallAction(call: blocked.id))
        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())
        manager.provider(provider, didDeactivate: AVAudioSession.sharedInstance())

        XCTAssertEqual(hostEnds, [call.id, blocked.id])
        XCTAssertEqual(reportedEnds, [call.id, blocked.id])
        XCTAssertEqual(activations, [call.id], "late activation remains quarantined to the timed-out UUID")
        XCTAssertEqual(deactivations, [call.id])

        manager.ring(fresh)
        manager.provider(provider, perform: CXAnswerCallAction(call: fresh.id))
        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(activations, [call.id, fresh.id], "a fresh call may proceed only after quarantine drains")
    }

    func test_provider_reset_releases_a_timed_out_activation_quarantine() {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        let manager = SentiCallManager(
            provider: provider,
            audioActivationTimeoutNanoseconds: 60_000_000_000
        )
        let timedOut = IncomingDecisionCall(
            id: UUID(), dialId: "dial-reset-timeout", callerDisplayName: "Senti", message: "", context: nil, priority: "high"
        )
        let fresh = IncomingDecisionCall(
            id: UUID(), dialId: "dial-after-reset", callerDisplayName: "Senti", message: "", context: nil, priority: "high"
        )
        var deactivations: [UUID] = []
        var activations: [UUID] = []
        manager.onAudioSessionDeactivated = { _, id in deactivations.append(id) }
        manager.onAudioSessionActivated = { _, id in activations.append(id) }

        manager.ring(timedOut)
        manager.provider(provider, perform: CXAnswerCallAction(call: timedOut.id))
        manager.expireAudioActivation(callUUID: timedOut.id)
        manager.providerDidReset(provider)

        XCTAssertEqual(deactivations, [timedOut.id])
        manager.ring(fresh)
        manager.provider(provider, perform: CXAnswerCallAction(call: fresh.id))
        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(activations, [fresh.id])
    }

    func test_end_before_activation_serializes_late_callbacks_away_from_next_call() {
        let provider = CXProvider(configuration: CXProviderConfiguration())
        var reportedEnds: [UUID] = []
        let manager = SentiCallManager(
            provider: provider,
            reportEndedCall: { reportedEnds.append($0) },
            audioActivationTimeoutNanoseconds: 60_000_000_000
        )
        let first = IncomingDecisionCall(
            id: UUID(), dialId: "dial-preactive-A", callerDisplayName: "Senti", message: "", context: nil, priority: "high"
        )
        let second = IncomingDecisionCall(
            id: UUID(), dialId: "dial-preactive-B", callerDisplayName: "Senti", message: "", context: nil, priority: "high"
        )
        let third = IncomingDecisionCall(
            id: UUID(), dialId: "dial-preactive-C", callerDisplayName: "Senti", message: "", context: nil, priority: "high"
        )
        var hostEnds: [UUID] = []
        var activations: [UUID] = []
        var deactivations: [UUID] = []
        manager.onEnded = { hostEnds.append($0) }
        manager.onAudioSessionActivated = { _, id in activations.append(id) }
        manager.onAudioSessionDeactivated = { _, id in deactivations.append(id) }

        manager.ring(first)
        manager.provider(provider, perform: CXAnswerCallAction(call: first.id))
        manager.end(first.id)
        manager.ring(second)
        manager.provider(provider, perform: CXAnswerCallAction(call: second.id))

        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())
        manager.provider(provider, didDeactivate: AVAudioSession.sharedInstance())

        XCTAssertEqual(activations, [first.id], "late activation must stay attributed to ended call A")
        XCTAssertEqual(deactivations, [first.id], "late deactivation must stay attributed to ended call A")
        XCTAssertEqual(hostEnds, [second.id], "call B is rejected while call A owns the callback slot")
        XCTAssertEqual(reportedEnds, [first.id, second.id])

        manager.ring(third)
        manager.provider(provider, perform: CXAnswerCallAction(call: third.id))
        manager.provider(provider, didActivate: AVAudioSession.sharedInstance())
        XCTAssertEqual(activations, [first.id, third.id], "call C may start only after call A fully deactivates")
    }
}
#endif
