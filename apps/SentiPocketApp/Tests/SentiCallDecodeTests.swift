#if canImport(CallKit) && canImport(PushKit)
import XCTest
import CallKit
import AVFoundation
@testable import SentiPocketApp

/// Locks SentiCallManager's decode (CallKit-ring DISPLAY) + receiveState (the DialReceiveState surfaced at push-receive).
/// The push fields are display-only — none drive the governed write (that's the hydrated ring via DialCoordinator).
@MainActor
final class SentiCallDecodeTests: XCTestCase {   // SentiCallManager is @MainActor, so its static decode()/receiveState() are too
    private let bindingId = "bind_0123456789abcdef0123456789abcdef"

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

    private func v2(_ payload: [String: Any], revision: Int = 7) -> [String: Any] {
        var result = payload
        result["v"] = 2
        result["binding"] = ["v": 2, "id": bindingId, "revision": revision]
        return result
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
            var enveloped: [AnyHashable: Any] = v2(payload)   // dial fields spread TOP-LEVEL...
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

    func test_registry_v2_nested_binding_decodes_the_exact_binding_proof() throws {
        let source = try loadFixture("dial-payload-v1.json")
        guard let cases = source["cases"] as? [String: Any],
              let raw = cases["writekind_decision_lean"] as? [String: Any],
              let payload = raw["payload"] as? [String: Any],
              let received = SentiCallManager.receiveState(from: v2(payload)) else {
            return XCTFail("Registry V2 nested binding must decode")
        }
        let core: RingCore
        switch received.state {
        case .renderable(let ring):
            core = ring.core
        case .needsHydration(_, let value):
            core = value
        case .rejected(let reason):
            return XCTFail("Registry V2 fixture rejected: \(reason)")
        }
        XCTAssertEqual(core.binding, DeviceRingBindingFence(id: bindingId, revision: 7))
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
              let raw = cases["writekind_decision_lean"] as? [String: Any],
              let payload = raw["payload"] as? [String: Any] else {
            return XCTFail("source fixture missing a payload")
        }

        let prepared = SentiCallManager.prepareIncomingPush(
            v2(payload),
            isBindingAuthorized: { _, _ in false }
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
              let raw = cases["writekind_decision_lean"] as? [String: Any],
              let payload = raw["payload"] as? [String: Any],
              let sessionId = payload["sessionId"] as? String else {
            return XCTFail("source fixture missing a session payload")
        }

        let prepared = SentiCallManager.prepareIncomingPush(
            v2(payload),
            isBindingAuthorized: { candidate, fence in
                candidate == sessionId && fence.id == self.bindingId && fence.revision == 7
            }
        )

        XCTAssertNotNil(prepared.state)
        XCTAssertEqual(prepared.dialId, payload["id"] as? String)
        XCTAssertEqual(prepared.call.dialId, payload["id"] as? String)
    }

    func test_v1_or_malformed_binding_is_generic_before_display_decode() throws {
        let source = try loadFixture("dial-payload-v1.json")
        guard let cases = source["cases"] as? [String: Any],
              let raw = cases["writekind_decision_lean"] as? [String: Any],
              var payload = raw["payload"] as? [String: Any] else {
            return XCTFail("source fixture missing a payload")
        }
        payload["callerName"] = "SECRET DISPLAY"
        var authorizationCalls = 0

        let v1 = SentiCallManager.prepareIncomingPush(
            payload,
            isBindingAuthorized: { _, _ in authorizationCalls += 1; return true }
        )
        XCTAssertEqual(v1.call.callerDisplayName, "Senti")
        XCTAssertNil(v1.state)
        XCTAssertEqual(authorizationCalls, 0, "V1 must fail raw preflight before the authority callback")

        payload = v2(payload)
        payload["binding"] = ["v": 2, "id": bindingId, "revision": true]
        let malformed = SentiCallManager.prepareIncomingPush(
            payload,
            isBindingAuthorized: { _, _ in authorizationCalls += 1; return true }
        )
        XCTAssertEqual(malformed.call.callerDisplayName, "Senti")
        XCTAssertNil(malformed.state)
        XCTAssertEqual(authorizationCalls, 0)
    }

    func test_partial_v2_proof_is_rejected_before_authorization() throws {
        let source = try loadFixture("dial-payload-v1.json")
        guard let cases = source["cases"] as? [String: Any],
              let raw = cases["writekind_decision_lean"] as? [String: Any],
              var payload = raw["payload"] as? [String: Any] else {
            return XCTFail("source fixture missing a payload")
        }
        payload = v2(payload)
        payload["binding"] = ["v": 2, "id": bindingId]
        var authorizationCalls = 0

        let prepared = SentiCallManager.prepareIncomingPush(
            payload,
            isBindingAuthorized: { _, _ in authorizationCalls += 1; return true }
        )

        XCTAssertNil(prepared.state, "a partial V2 tuple must reject, never downgrade")
        XCTAssertEqual(prepared.call.callerDisplayName, "Senti")
        XCTAssertEqual(authorizationCalls, 0)
    }

    func test_push_completion_and_hydration_wait_for_successful_callkit_report() async throws {
        let source = try loadFixture("dial-payload-v1.json")
        guard let cases = source["cases"] as? [String: Any],
              let raw = cases["writekind_decision_lean"] as? [String: Any],
              let payload = raw["payload"] as? [String: Any] else {
            return XCTFail("source fixture missing a payload")
        }
        let provider = CXProvider(configuration: CXProviderConfiguration())
        var reportCallback: (@MainActor @Sendable (Bool) -> Void)?
        let manager = SentiCallManager(
            provider: provider,
            reportIncomingCall: { _, _, completion in reportCallback = completion }
        )
        manager.isIncomingBindingAuthorized = { _, _ in true }
        var received: [(String, UUID)] = []
        manager.onDialReceived = { _, dialId, callUUID in received.append((dialId, callUUID)) }
        var pushCompletionCount = 0

        manager.handleIncomingPushPayload(v2(payload)) { pushCompletionCount += 1 }

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
              let raw = cases["writekind_decision_lean"] as? [String: Any],
              let payload = raw["payload"] as? [String: Any] else {
            return XCTFail("source fixture missing a payload")
        }
        let provider = CXProvider(configuration: CXProviderConfiguration())
        var reportCallback: (@MainActor @Sendable (Bool) -> Void)?
        let manager = SentiCallManager(
            provider: provider,
            reportIncomingCall: { _, _, completion in reportCallback = completion }
        )
        manager.isIncomingBindingAuthorized = { _, _ in true }
        var receivedCount = 0
        manager.onDialReceived = { _, _, _ in receivedCount += 1 }
        var pushCompletionCount = 0

        manager.handleIncomingPushPayload(v2(payload)) { pushCompletionCount += 1 }
        reportCallback?(false)
        for _ in 0..<3 { await Task.yield() }

        XCTAssertEqual(pushCompletionCount, 1)
        XCTAssertEqual(receivedCount, 0)
    }

    func test_revoke_during_report_tombstones_late_success_and_never_resurrects_state() async throws {
        let source = try loadFixture("dial-payload-v1.json")
        guard let cases = source["cases"] as? [String: Any],
              let raw = cases["writekind_decision_lean"] as? [String: Any],
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
        manager.isIncomingBindingAuthorized = { _, _ in true }
        var receivedCount = 0
        manager.onDialReceived = { _, _, _ in receivedCount += 1 }
        var pushCompletionCount = 0

        manager.handleIncomingPushPayload(v2(payload)) { pushCompletionCount += 1 }
        manager.revokeAllCalls()
        reportCallback?(true)
        for _ in 0..<3 { await Task.yield() }

        XCTAssertEqual(pushCompletionCount, 1)
        XCTAssertEqual(receivedCount, 0)
        XCTAssertEqual(reportedEnds.count, 1, "late CallKit success must be ended after authority was revoked")
    }

    func test_binding_loss_after_successful_callkit_report_ends_exact_uuid_without_publishing_state() async throws {
        let source = try loadFixture("dial-payload-v1.json")
        guard let cases = source["cases"] as? [String: Any],
              let raw = cases["writekind_decision_lean"] as? [String: Any],
              let payload = raw["payload"] as? [String: Any] else {
            return XCTFail("source fixture missing named decision payload")
        }
        let provider = CXProvider(configuration: CXProviderConfiguration())
        var reportCallback: (@MainActor @Sendable (Bool) -> Void)?
        var reportedUUID: UUID?
        var reportedEnds: [UUID] = []
        var authorizationChecks = 0
        let manager = SentiCallManager(
            provider: provider,
            reportIncomingCall: { uuid, _, completion in
                reportedUUID = uuid
                reportCallback = completion
            },
            reportEndedCall: { reportedEnds.append($0) }
        )
        manager.isIncomingBindingAuthorized = { _, _ in
            authorizationChecks += 1
            return authorizationChecks == 1
        }
        var receivedCount = 0
        manager.onDialReceived = { _, _, _ in receivedCount += 1 }
        var pushCompletionCount = 0

        manager.handleIncomingPushPayload(v2(payload)) { pushCompletionCount += 1 }
        reportCallback?(true)
        for _ in 0..<3 { await Task.yield() }

        XCTAssertEqual(pushCompletionCount, 1)
        XCTAssertEqual(receivedCount, 0)
        XCTAssertEqual(reportedEnds, reportedUUID.map { [$0] } ?? [])
    }

    func test_cached_pushkit_token_is_replayed_before_incoming_binding_authorization() async throws {
        let source = try loadFixture("dial-payload-v1.json")
        guard let cases = source["cases"] as? [String: Any],
              let raw = cases["writekind_decision_lean"] as? [String: Any],
              let payload = raw["payload"] as? [String: Any] else {
            return XCTFail("source fixture missing named decision payload")
        }
        let provider = CXProvider(configuration: CXProviderConfiguration())
        var events: [String] = []
        let completion = expectation(description: "PushKit completion after cached-token replay")
        let manager = SentiCallManager(
            provider: provider,
            currentVoipToken: { "aabbcc" }
        )
        manager.onVoipToken = { token in events.append("token:\(token)") }
        manager.isIncomingBindingAuthorized = { _, _ in
            events.append("gate")
            return true
        }

        manager.handleIncomingPushPayload(v2(payload)) {
            completion.fulfill()
        }
        await fulfillment(of: [completion], timeout: 1)

        XCTAssertEqual(Array(events.prefix(2)), ["token:aabbcc", "gate"])
        XCTAssertEqual(events.filter { $0 == "gate" }.count, 2)
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
