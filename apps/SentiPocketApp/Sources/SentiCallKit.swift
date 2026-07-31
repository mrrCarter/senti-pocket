// SentiCallKit — the device-side "Pocket rings like a phone call" binding for DIALS ("Senti Pocket dials Carter",
// Carter #266304). forge lane (atlas's map: the CallKit answer-audio-session). Two ways in, ONE ring:
//   1. FOREGROUND (demoable TODAY, no account): `presentDemoRing()` / `ring(_:)` reports a native incoming call from
//      the running app — full-screen, rings, vibrates, lock-screen UI. No VoIP cert needed.
//   2. BACKGROUND/KILLED (the real product): a PushKit VoIP push wakes the app and we report the SAME call. The only
//      external dependency is an APNs VoIP credential from Carter's Apple Developer account — that gates live DELIVERY,
//      not this code (everything here compiles + is exercisable without it).
// On answer we hand an IncomingDecisionCall to the orchestrator, which drives PocketCallMachine `.answered` → briefing
// → converse → confirm → governed writeback. This is an APP VoIP call — NO PSTN / NO Twilio (that would be a v2 fallback).
//
// SCOPE: device PLUMBING only. The rich /dial VoIP payload contract is relay's wire (gateway POST /dial); `decode(_:)`
// reads only what CallKit needs (id / who / priority) and ALWAYS yields a presentable call. A malformed, signed-out,
// or unselected push is still reported as iOS requires, but with generic redacted metadata and no retained answer state.
#if canImport(CallKit) && canImport(PushKit)
import AVFoundation
import CallKit
import Foundation
import PushKit

/// The incoming "decision call" the DialOrchestrator acts on, decoded from relay's dial-registry `buildDialPayload`
/// wire (`{ id:'dial_…', who, priority, message, context?, sessionId, ts }`). `id` here is a fresh CallKit UUID
/// (CallKit requires a UUID); `dialId` is relay's correlation id to echo back with the answer/confirm.
public struct IncomingDecisionCall: Equatable, Sendable {
    public let id: UUID           // CallKit call UUID (generated — relay's dialId is not a UUID)
    public let dialId: String     // relay's /dial correlation id ('dial_…') — echo back with the answer/confirm
    public let callerDisplayName: String
    public let message: String    // the decision text (read-back for warden's bar 2b / the briefing)
    public let context: String?   // optional "what we need" context from the ring
    public let priority: String   // low | medium | high | urgent (relay's DIAL_PRIORITIES; default medium)
    public init(id: UUID, dialId: String, callerDisplayName: String, message: String, context: String?, priority: String) {
        self.id = id
        self.dialId = dialId
        self.callerDisplayName = callerDisplayName
        self.message = message
        self.context = context
        self.priority = priority
    }
}

@MainActor
public final class SentiCallManager: NSObject {
    /// The device VoIP push token (lowercase hex). Send it to the gateway's /dial registry so a ring can target THIS
    /// device — bound at authenticated login → the outbound-binding substrate for warden's consent gate.
    public var onVoipToken: ((String) -> Void)?
    /// The human ANSWERED the ring → begin the briefing/converse flow (wire to PocketCallMachine `.answered`).
    public var onAnswered: ((IncomingDecisionCall) -> Void)?
    /// A VoIP push ARRIVED → the LEAN/RICH `DialReceiveState` decoded from it (+ relay's dialId), fired at RECEIVE so
    /// the DialCoordinator stores it for the answer's hydrate. Governed content is fetched on answer (authed GET),
    /// NEVER carried here — this only surfaces the ring shape + the dialId. Decoded via the KAV-locked DialReceive.receive.
    /// (internal, not public: DialReceiveState is app-internal; the DialHost consumer is in-module.)
    var onDialReceived: ((DialReceiveState, String) -> Void)?
    /// Receive-time privacy gate installed by DialHost. Durable server registrations can outlive a local selection,
    /// so push metadata is exposed and retained only for the exact currently selected authorized session.
    var isIncomingSessionAuthorized: ((String) -> Bool)?
    /// The call ended / was declined → tear down (stop audio, drop the episode).
    public var onEnded: ((UUID) -> Void)?
    /// CallKit ACTIVATED the audio session → safe to start capture/playback (hand to PocketVoice's DuplexAudioSessionLease).
    public var onAudioSessionActivated: ((AVAudioSession) -> Void)?

    private let provider: CXProvider
    private let pushRegistry: PKPushRegistry?
    private let reportIncomingCall: (UUID, CXCallUpdate) -> Void
    private let reportEndedCall: (UUID) -> Void
    private var active: [UUID: IncomingDecisionCall] = [:]

    public override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.includesCallsInRecents = false     // a decision ring is not a phone call to log in Recents
        configuration.supportedHandleTypes = [.generic]
        let provider = CXProvider(configuration: configuration)
        let pushRegistry = PKPushRegistry(queue: .main)
        self.provider = provider
        self.pushRegistry = pushRegistry
        self.reportIncomingCall = { id, update in
            provider.reportNewIncomingCall(with: id, update: update, completion: { _ in })
        }
        self.reportEndedCall = { id in
            provider.reportCall(with: id, endedAt: nil, reason: .remoteEnded)
        }
        super.init()
        provider.setDelegate(self, queue: nil)            // nil → main queue
        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]
    }

    /// Hermetic lifecycle-test initializer: no PushKit registration and no real CallKit report side effects.
    init(
        provider: CXProvider,
        reportIncomingCall: @escaping (UUID, CXCallUpdate) -> Void = { _, _ in },
        reportEndedCall: @escaping (UUID) -> Void = { _ in }
    ) {
        self.provider = provider
        self.pushRegistry = nil
        self.reportIncomingCall = reportIncomingCall
        self.reportEndedCall = reportEndedCall
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// Present the native incoming-call UI for a decision ring. Foreground-capable (demoable without a VoIP cert) and
    /// also the target of the PushKit path.
    public func ring(_ call: IncomingDecisionCall) {
        active[call.id] = call
        let update = CXCallUpdate()
        update.localizedCallerName = call.callerDisplayName
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        update.remoteHandle = CXHandle(type: .generic, value: "senti-\(call.priority)")
        // The report completion is @Sendable, so we touch no main-actor state in it. A (rare) report failure leaves a
        // harmless stale `active` entry — no answer/end will arrive for it, and providerDidReset clears it.
        reportIncomingCall(call.id, update)
    }

    /// Demo convenience: ring from the foreground with no VoIP cert — Carter sees the native call UI today.
    public func presentDemoRing(
        callerName: String = "Senti — decision needed",
        message: String = "A decision needs your go.",
        priority: String = "high"
    ) {
        ring(IncomingDecisionCall(
            id: UUID(), dialId: "demo", callerDisplayName: callerName, message: message, context: nil, priority: priority
        ))
    }

    /// Programmatically end an active call (e.g., the governed writeback finished and we hang up).
    public func end(_ id: UUID) {
        guard active.removeValue(forKey: id) != nil else { return }
        reportEndedCall(id)
    }

    /// Revoke ringing and answered calls together. Selection/auth transitions cannot wait for an answer before
    /// removing metadata; notify the host synchronously so any governed flow is cancelled before CallKit cleanup.
    func revokeAllCalls() {
        let ids = Array(active.keys)
        active.removeAll()
        for id in ids {
            onEnded?(id)
            reportEndedCall(id)
        }
    }
}

extension SentiCallManager: @preconcurrency CXProviderDelegate {
    public func providerDidReset(_ provider: CXProvider) {
        let ids = Array(active.keys)
        active.removeAll()
        for id in ids {
            onEnded?(id)
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        if let call = active[action.callUUID] { onAnswered?(call) }
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if active.removeValue(forKey: action.callUUID) != nil {
            onEnded?(action.callUUID)
        }
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        onAudioSessionActivated?(audioSession)
    }
}

extension SentiCallManager: @preconcurrency PKPushRegistryDelegate {
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        onVoipToken?(token)
    }

    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        // Token invalidated → the gateway should drop it; a fresh `didUpdate` follows on re-register.
    }

    /// iOS 13+: on a VoIP push we MUST report an incoming call to CallKit BEFORE calling completion(), or the app is
    /// terminated (and repeat offenders lose VoIP push). `ring` reports synchronously, then we complete.
    public func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else { completion(); return }
        let dict = payload.dictionaryPayload
        let prepared = Self.prepareIncomingPush(
            dict,
            isSessionAuthorized: isIncomingSessionAuthorized ?? { _ in false }
        )
        // Report the incoming call (inside `ring`) BEFORE completion() — the iOS 13+ requirement.
        ring(prepared.call)
        // ALSO surface the full DialReceiveState for the coordinator to hydrate on answer, via the extracted+tested
        // receiveState() so the ENVELOPED-push round-trip has coverage (relay's find). Reuses the KAV-locked
        // DialReceive.receive — never a 2nd decoder. Governed content stays behind the authed GET.
        if let state = prepared.state, let dialId = prepared.dialId {
            onDialReceived?(state, dialId)
        }
        completion()
    }

    /// Fail-safe decode of relay's dial-registry `buildDialPayload` wire → always a presentable call (a malformed push
    /// still rings — never a silently-dropped delivery; the orchestrator re-validates the full episode on answer).
    /// Wire: `{ id:'dial_…', who, priority(low|medium|high|urgent), message, context?, sessionId, ts }`.
    /// Decode the ENVELOPED VoIP push dict (APNs `{ aps:{…}, <dial DTO TOP-LEVEL> }`) → the DialReceiveState + relay's
    /// dialId, via the SAME KAV-locked DialReceive.receive (#96). The dial fields are read TOP-LEVEL (the `aps` envelope
    /// is ignored by the Codable). DEPLOY CONTRACT (relay): apnsSend MUST place the dial DTO top-level, NOT nested — if
    /// top-level `id` is absent (a nested/malformed envelope) this returns nil, so the coordinator simply has no state
    /// for that ring (declines on answer) rather than a silent wrong-decode.
    static func receiveState(from dict: [AnyHashable: Any]) -> (state: DialReceiveState, dialId: String)? {
        // isValidJSONObject FIRST: data(withJSONObject:) raises an NSException (NOT a Swift error) on a non-conforming
        // dict, which `try?` does NOT catch → it would CRASH on a malformed push. Guarding returns the fail-safe nil.
        // (warden #5b; atlas + relay both caught it independently — a malformed VoIP push must never crash the app.)
        guard let dialId = dict["id"] as? String,
              JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return (DialReceive.receive(data), dialId)
    }

    /// iOS requires every VoIP push to be reported to CallKit. An old server-side registration may still deliver a
    /// push after sign-out/selection change, so unauthorized or malformed payloads become a generic, non-actionable
    /// call: no caller/message/context/priority metadata is exposed and no hydration state is retained.
    static func prepareIncomingPush(
        _ payload: [AnyHashable: Any],
        isSessionAuthorized: (String) -> Bool
    ) -> (call: IncomingDecisionCall, state: DialReceiveState?, dialId: String?) {
        let decoded = decode(payload)
        guard let received = receiveState(from: payload),
              let sessionId = sessionId(from: received.state),
              isSessionAuthorized(sessionId) else {
            return (
                IncomingDecisionCall(
                    id: decoded.id,
                    dialId: decoded.dialId,
                    callerDisplayName: "Senti",
                    message: "",
                    context: nil,
                    priority: "medium"
                ),
                nil,
                nil
            )
        }
        return (decoded, received.state, received.dialId)
    }

    private static func sessionId(from state: DialReceiveState) -> String? {
        switch state {
        case .renderable(let ring):
            return ring.core.sessionId
        case .needsHydration(_, let core):
            return core.sessionId
        case .rejected:
            return nil
        }
    }

    static func decode(_ payload: [AnyHashable: Any]) -> IncomingDecisionCall {
        let dialId = (payload["id"] as? String) ?? ""                       // relay's 'dial_…' correlation id (not a UUID)
        let message = (payload["message"] as? String) ?? ""
        let who = (payload["who"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let callerName = (payload["callerName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let named = !callerName.isEmpty ? callerName : who   // warden's minor: prefer the nicer callerName over `who`
        let display = !named.isEmpty ? named : (message.isEmpty ? "Senti — decision needed" : message)
        let raw = (payload["priority"] as? String) ?? "medium"
        let priority = ["low", "medium", "high", "urgent"].contains(raw) ? raw : "medium"
        let context = (payload["context"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return IncomingDecisionCall(
            id: UUID(),                                                     // CallKit UUID; dialId carries relay's id
            dialId: dialId,
            callerDisplayName: String(display.prefix(80)),
            message: message,
            context: context,
            priority: priority
        )
    }
}
#endif
