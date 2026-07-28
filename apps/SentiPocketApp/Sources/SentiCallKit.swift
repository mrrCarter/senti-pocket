// SentiCallKit — the device-side "Pocket rings like a phone call" binding for DIALS ("Senti Pocket dials Carter",
// Carter #266304). forge lane (atlas's map: the CallKit answer-audio-session). Two ways in, ONE ring:
//   1. FOREGROUND (demoable TODAY, no account): `ring(_:)` reports a native incoming call from the running app —
//      full-screen, rings, vibrates, lock-screen UI. No VoIP cert needed. The foreground DEMO trigger lives in
//      DialHost.presentForegroundDial (it SEEDS the coordinator's pending state BEFORE ringing, so the answer hydrates
//      + reaches the pickup voice instead of declining) — gated OFF by default behind POCKET_DEMO_DIAL_ENABLED. The old
//      `presentDemoRing()` convenience was REMOVED: it minted a dialId="demo" that seeded NO DialReceiveState, so the
//      coordinator always declined it (an orphan ring that never reached the voice).
//   2. BACKGROUND/KILLED (the real product): a PushKit VoIP push wakes the app and we report the SAME call. The only
//      external dependency is an APNs VoIP credential from Carter's Apple Developer account — that gates live DELIVERY,
//      not this code (everything here compiles + is exercisable without it).
// On answer we hand an IncomingDecisionCall to the orchestrator, which drives PocketCallMachine `.answered` → briefing
// → converse → confirm → governed writeback. This is an APP VoIP call — NO PSTN / NO Twilio (that would be a v2 fallback).
//
// SCOPE: device PLUMBING only. The rich /dial VoIP payload contract is relay's wire (gateway POST /dial); `decode(_:)`
// reads only what CallKit needs (id / who / priority) and ALWAYS yields a presentable call, so a malformed or partial
// push still RINGS (a delivery is never silently dropped) and the orchestrator re-validates the episode on answer.
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

/// The MINIMAL end-of-call fact (spec B): the CallKit UUID + the ring's `dialId` (resolved from `active` BEFORE the
/// call is forgotten). Deliberately NOT the whole IncomingDecisionCall — teardown must not depend on any untrusted
/// push field; it needs only which CallKit call ended and which pending ring (if any) to discard.
public struct CallEndEvent: Equatable, Sendable {
    public let callUUID: UUID
    public let dialId: String?
    public init(callUUID: UUID, dialId: String?) { self.callUUID = callUUID; self.dialId = dialId }
}

/// CallEndRouter — the ONE idempotent teardown path (spec B). CXEndCallAction, providerDidReset, AND a
/// reportNewIncomingCall failure all funnel through `teardown`, so every way a call dies runs identical cleanup
/// EXACTLY once. Pure (no CallKit types), so it is unit-testable without a live CXProvider. SentiCallManager owns one,
/// feeds it the dialId at ring-time, and forwards the resolved CallEndEvent to its `onEnd`.
@MainActor
final class CallEndRouter {
    /// callUUID → the resolved end event (built at ring-time so the dialId survives the call being forgotten).
    private var live: [UUID: CallEndEvent] = [:]
    /// UUIDs the FLOW itself terminated (SentiCallManager.end) — their own completing episode must NOT be torn down
    /// again (recursive self-cancel). The next teardown for such a UUID is swallowed.
    private var programmaticallyEnded: Set<UUID> = []
    /// Fan a resolved end out to the owner (DialHost episode teardown). Fired at most once per call.
    var onEnd: ((CallEndEvent) -> Void)?

    /// Track a ringing call so a later end resolves its dialId BEFORE the call is forgotten.
    func track(callUUID: UUID, dialId: String?) {
        live[callUUID] = CallEndEvent(callUUID: callUUID, dialId: dialId)
    }

    /// Mark a terminal end the FLOW itself initiated (SentiCallManager.end) — swallow the next teardown for this UUID
    /// so the completing episode is not recursively self-cancelled.
    func markProgrammaticEnd(callUUID: UUID) {
        programmaticallyEnded.insert(callUUID)
        live[callUUID] = nil
    }

    /// The idempotent teardown. Resolves + fires the CallEndEvent exactly once, then forgets the call. A second call
    /// for the same UUID (already forgotten) is a harmless no-op. A flow-initiated (programmatic) end is swallowed.
    func teardown(callUUID: UUID) {
        if programmaticallyEnded.remove(callUUID) != nil { live[callUUID] = nil; return }
        guard let event = live.removeValue(forKey: callUUID) else { return }
        onEnd?(event)
    }

    /// Fan a provider RESET out over ALL tracked calls — each through the SAME idempotent teardown.
    func teardownAll() {
        for uuid in Array(live.keys) { teardown(callUUID: uuid) }
    }

    /// Test hook: how many calls are currently tracked (0 after every end has been routed).
    var trackedCount: Int { live.count }
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
    /// The call ended / was declined / failed to present → tear down (stop audio, drop the episode). Carries the
    /// resolved CallEndEvent (callUUID + dialId), routed through the SINGLE idempotent CallEndRouter path (spec B).
    public var onEndEvent: ((CallEndEvent) -> Void)?
    /// CallKit ACTIVATED the audio session → safe to start capture/playback (hand to PocketVoice's DuplexAudioSessionLease).
    public var onAudioSessionActivated: ((AVAudioSession) -> Void)?

    private let provider: CXProvider
    private let pushRegistry: PKPushRegistry
    private var active: [UUID: IncomingDecisionCall] = [:]
    /// The ONE idempotent teardown path — CXEndCallAction, providerDidReset, and a report-failure all funnel here.
    let endRouter = CallEndRouter()

    public override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.includesCallsInRecents = false     // a decision ring is not a phone call to log in Recents
        configuration.supportedHandleTypes = [.generic]
        provider = CXProvider(configuration: configuration)
        pushRegistry = PKPushRegistry(queue: .main)
        super.init()
        provider.setDelegate(self, queue: nil)            // nil → main queue
        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]
        // Forward every resolved end (from the single router) to the episode owner.
        endRouter.onEnd = { [weak self] event in self?.onEndEvent?(event) }
    }

    /// Present the native incoming-call UI for a decision ring. Foreground-capable (demoable without a VoIP cert) and
    /// also the target of the PushKit path.
    public func ring(_ call: IncomingDecisionCall) {
        active[call.id] = call
        endRouter.track(callUUID: call.id, dialId: call.dialId)   // resolve the dialId NOW, so a later end is clean
        let update = CXCallUpdate()
        update.localizedCallerName = call.callerDisplayName
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        update.remoteHandle = CXHandle(type: .generic, value: "senti-\(call.priority)")
        // A report FAILURE (previously IGNORED) must run the SAME idempotent teardown (spec B) — otherwise a call that
        // never presented leaks a stale active/router entry AND a seeded-but-unanswerable pending ring. The completion
        // is @Sendable, so hop to the main actor to run the teardown. No error → the answer/end path drives teardown.
        let callId = call.id
        provider.reportNewIncomingCall(with: call.id, update: update, completion: { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.handleReportFailure(callUUID: callId) }
        })
    }

    /// Programmatically end an active call (e.g., the governed writeback finished and we hang up). Marked programmatic
    /// so the router swallows the follow-on teardown — the flow's OWN completing episode is never self-cancelled.
    public func end(_ id: UUID) {
        endRouter.markProgrammaticEnd(callUUID: id)
        provider.reportCall(with: id, endedAt: nil, reason: .remoteEnded)
        active[id] = nil
    }

    /// A reportNewIncomingCall failure → route through the SAME idempotent teardown as a hangup/reset (spec B).
    private func handleReportFailure(callUUID: UUID) {
        active[callUUID] = nil
        endRouter.teardown(callUUID: callUUID)
    }
}

extension SentiCallManager: @preconcurrency CXProviderDelegate {
    public func providerDidReset(_ provider: CXProvider) {
        // Fan the reset out over ALL captured active calls through the SAME idempotent teardown (spec B). Previously
        // this was a bare active.removeAll(), which dropped the bookkeeping but left every live episode RUNNING.
        endRouter.teardownAll()
        active.removeAll()
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        if let call = active[action.callUUID] { onAnswered?(call) }
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        // The SINGLE teardown path resolves the dialId + fans out BEFORE we forget the call (spec B).
        endRouter.teardown(callUUID: action.callUUID)
        active[action.callUUID] = nil
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
        // Report the incoming call (inside `ring`) BEFORE completion() — the iOS 13+ requirement.
        ring(Self.decode(dict))
        // ALSO surface the full DialReceiveState for the coordinator to hydrate on answer, via the extracted+tested
        // receiveState() so the ENVELOPED-push round-trip has coverage (relay's find). Reuses the KAV-locked
        // DialReceive.receive — never a 2nd decoder. Governed content stays behind the authed GET.
        if let (state, dialId) = Self.receiveState(from: dict) {
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
