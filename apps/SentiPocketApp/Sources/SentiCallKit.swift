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
    /// PushKit invalidated the current token. Revoke the accepted binding immediately; a later didUpdate registers anew.
    public var onVoipTokenInvalidated: (() -> Void)?
    /// The human ANSWERED the ring → begin the briefing/converse flow (wire to PocketCallMachine `.answered`).
    public var onAnswered: ((IncomingDecisionCall) -> Void)?
    /// A VoIP push ARRIVED → the LEAN/RICH `DialReceiveState` decoded from it (+ relay's dialId), fired at RECEIVE so
    /// the DialCoordinator stores it for the answer's hydrate. Governed content is fetched on answer (authed GET),
    /// NEVER carried here — this only surfaces the ring shape + the dialId. Decoded via the KAV-locked DialReceive.receive.
    /// (internal, not public: DialReceiveState is app-internal; the DialHost consumer is in-module.)
    var onDialReceived: ((DialReceiveState, String, UUID) -> Void)?
    /// Receive-time Registry V2 gate installed by DialHost. Parse only the raw session/binding fence before touching
    /// display or governed fields, then recheck the same fence after CallKit accepts the report.
    var isIncomingBindingAuthorized: ((String, DeviceRingBindingFence) -> Bool)?
    /// The call ended / was declined → tear down (stop audio, drop the episode).
    public var onEnded: ((UUID) -> Void)?
    /// CallKit ACTIVATED the audio session → safe to start capture/playback (hand to PocketVoice's DuplexAudioSessionLease).
    public var onAudioSessionActivated: ((AVAudioSession, UUID) -> Void)?
    /// CallKit DEACTIVATED audio. Any running or activation-waiting dial must stop before it can speak or write.
    public var onAudioSessionDeactivated: ((AVAudioSession, UUID) -> Void)?

    private let provider: CXProvider
    private let pushRegistry: PKPushRegistry?
    private let currentVoipTokenProvider: () -> String?
    private let reportIncomingCall: @MainActor (
        UUID,
        CXCallUpdate,
        @escaping @MainActor @Sendable (Bool) -> Void
    ) -> Void
    private let reportEndedCall: (UUID) -> Void
    private var active: [UUID: IncomingDecisionCall] = [:]
    private struct PendingIncomingReport {
        let call: IncomingDecisionCall
        let completion: ((Bool) -> Void)?
        var cancelled: Bool
    }
    private var pendingReports: [UUID: PendingIncomingReport] = [:]
    private var answeredCallAwaitingAudio: UUID?
    private var audioActiveCall: UUID?
    private var audioActivationDeadlineTask: Task<Void, Never>?
    private let audioActivationTimeoutNanoseconds: UInt64

    public override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.maximumCallGroups = 1
        configuration.includesCallsInRecents = false
        configuration.supportedHandleTypes = [.generic]
        let provider = CXProvider(configuration: configuration)
        let pushRegistry = PKPushRegistry(queue: .main)
        self.provider = provider
        self.pushRegistry = pushRegistry
        self.currentVoipTokenProvider = { [weak pushRegistry] in
            guard let data = pushRegistry?.pushToken(for: .voIP), !data.isEmpty else { return nil }
            return Self.hexToken(data)
        }
        self.reportIncomingCall = { id, update, completion in
            provider.reportNewIncomingCall(with: id, update: update) { error in
                Task { @MainActor in completion(error == nil) }
            }
        }
        self.reportEndedCall = { id in
            provider.reportCall(with: id, endedAt: nil, reason: .remoteEnded)
        }
        self.audioActivationTimeoutNanoseconds = 8_000_000_000
        super.init()
        provider.setDelegate(self, queue: nil)            // nil → main queue
        pushRegistry.delegate = self
        pushRegistry.desiredPushTypes = [.voIP]
    }

    /// Hermetic lifecycle-test initializer: no PushKit registration, provider delegate callbacks, or real CallKit
    /// report side effects. Tests invoke delegate methods directly when exercising provider lifecycle behavior.
    init(
        provider: CXProvider,
        currentVoipToken: @escaping () -> String? = { nil },
        reportIncomingCall: @escaping @MainActor (
            UUID,
            CXCallUpdate,
            @escaping @MainActor @Sendable (Bool) -> Void
        ) -> Void = { _, _, completion in completion(true) },
        reportEndedCall: @escaping (UUID) -> Void = { _ in },
        audioActivationTimeoutNanoseconds: UInt64 = 8_000_000_000
    ) {
        self.provider = provider
        self.pushRegistry = nil
        self.currentVoipTokenProvider = currentVoipToken
        self.reportIncomingCall = reportIncomingCall
        self.reportEndedCall = reportEndedCall
        self.audioActivationTimeoutNanoseconds = audioActivationTimeoutNanoseconds
        super.init()
    }

    /// PushKit retains the current token. Replaying it closes the killed-launch ordering where the delegate callback
    /// occurred in an earlier process but a push or authenticated selection arrives before another rotation callback.
    var currentVoipToken: String? {
        currentVoipTokenProvider()
    }

    func replayCurrentVoipToken() {
        guard let token = currentVoipToken else { return }
        onVoipToken?(token)
    }

    private static func hexToken(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Present the native incoming-call UI for a decision ring. Foreground-capable (demoable without a VoIP cert) and
    /// also the target of the PushKit path.
    public func ring(
        _ call: IncomingDecisionCall,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard active[call.id] == nil, pendingReports[call.id] == nil else {
            completion?(false)
            return
        }
        let update = CXCallUpdate()
        update.localizedCallerName = call.callerDisplayName
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        update.remoteHandle = CXHandle(type: .generic, value: "senti-\(call.priority)")
        pendingReports[call.id] = PendingIncomingReport(
            call: call,
            completion: completion,
            cancelled: false
        )
        // CallKit may invoke its completion off the main actor. Hop back before admitting the call into `active`.
        // The call and its hydration state stay unavailable until CallKit explicitly accepts the report.
        reportIncomingCall(call.id, update) { [weak self] succeeded in
            self?.finishIncomingReport(id: call.id, succeeded: succeeded)
        }
    }

    private func finishIncomingReport(id: UUID, succeeded: Bool) {
        // A hostile/double callback is ignored after the first removal, so the PushKit completion chained to this
        // attempt can fire at most once.
        guard let pending = pendingReports.removeValue(forKey: id) else { return }
        guard succeeded, !pending.cancelled else {
            // Revocation can race an in-flight CallKit report. If CallKit accepted it after authority was revoked,
            // immediately end the now-visible generic call; never resurrect answer or hydration state.
            if succeeded, pending.cancelled {
                reportEndedCall(id)
            }
            pending.completion?(false)
            return
        }
        active[id] = pending.call
        pending.completion?(true)
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
        if active.removeValue(forKey: id) != nil {
            // If this answer was already fulfilled, retain its awaiting/active UUID until CallKit delivers the
            // provider-wide audio callback (or the bounded activation deadline expires). Otherwise a late callback
            // for call A could be misattributed to a newly answered call B.
            reportEndedCall(id)
            return
        }
        if pendingReports[id] != nil {
            pendingReports[id]?.cancelled = true
        }
    }

    /// Revoke ringing and answered calls together. Selection/auth transitions cannot wait for an answer before
    /// removing metadata; notify the host synchronously so any governed flow is cancelled before CallKit cleanup.
    func revokeAllCalls() {
        let ids = Array(active.keys)
        active.removeAll()
        for id in Array(pendingReports.keys) {
            pendingReports[id]?.cancelled = true
        }
        for id in ids {
            onEnded?(id)
            reportEndedCall(id)
        }
    }

    private func armAudioActivationDeadline(for callUUID: UUID) {
        audioActivationDeadlineTask?.cancel()
        let timeout = audioActivationTimeoutNanoseconds
        audioActivationDeadlineTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.expireAudioActivation(callUUID: callUUID)
        }
    }

    private func cancelAudioActivationDeadline() {
        audioActivationDeadlineTask?.cancel()
        audioActivationDeadlineTask = nil
    }

    /// Internal for deterministic lifecycle tests. A fulfilled answer may not keep its governed flow alive forever
    /// while CallKit audio is missing: expiry ends the still-live call exactly once. Because CXProvider is global and
    /// its audio callbacks have no UUID, the ended UUID remains a fail-closed quarantine until didActivate followed by
    /// didDeactivate, a direct didDeactivate, or providerDidReset. We intentionally prefer rejecting later calls over
    /// ever attributing a delayed callback to the wrong human decision episode.
    func expireAudioActivation(callUUID: UUID) {
        guard answeredCallAwaitingAudio == callUUID else { return }
        cancelAudioActivationDeadline()
        if active.removeValue(forKey: callUUID) != nil {
            onEnded?(callUUID)
            reportEndedCall(callUUID)
        }
    }
}

extension SentiCallManager: @preconcurrency CXProviderDelegate {
    public func providerDidReset(_ provider: CXProvider) {
        let ids = Array(active.keys)
        let audioEpisodeCall = audioActiveCall ?? answeredCallAwaitingAudio
        active.removeAll()
        answeredCallAwaitingAudio = nil
        audioActiveCall = nil
        cancelAudioActivationDeadline()
        for id in Array(pendingReports.keys) {
            pendingReports[id]?.cancelled = true
        }
        for id in ids {
            onEnded?(id)
        }
        // CallKit documents reset as terminating every provider call, but a separate didDeactivate callback is not
        // guaranteed. Explicitly release PocketVoice's shared CallKit-ownership state so the next episode can acquire.
        if let audioEpisodeCall {
            onAudioSessionDeactivated?(AVAudioSession.sharedInstance(), audioEpisodeCall)
        }
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let call = active[action.callUUID] else {
            action.fail()
            return
        }
        if let serializedOwner = audioActiveCall ?? answeredCallAwaitingAudio {
            action.fail()
            // A duplicate system action for the current owner must not tear down its valid episode. A different call
            // cannot enter while an earlier UUID still owns a provider-wide audio callback; end it fail-closed.
            if serializedOwner != action.callUUID,
               active.removeValue(forKey: action.callUUID) != nil {
                onEnded?(action.callUUID)
                reportEndedCall(action.callUUID)
            }
            return
        }
        onAnswered?(call)
        // The host can synchronously reject/end during onAnswered (selection loss, stale UUID, or audio setup
        // failure). Never tell CallKit an already-ended answer succeeded.
        guard active[action.callUUID] != nil else {
            action.fail()
            return
        }
        answeredCallAwaitingAudio = action.callUUID
        armAudioActivationDeadline(for: action.callUUID)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        if active.removeValue(forKey: action.callUUID) != nil {
            onEnded?(action.callUUID)
        }
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        guard let callUUID = answeredCallAwaitingAudio,
              audioActiveCall == nil || audioActiveCall == callUUID else { return }
        cancelAudioActivationDeadline()
        answeredCallAwaitingAudio = nil
        audioActiveCall = callUUID
        onAudioSessionActivated?(audioSession, callUUID)
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        guard let callUUID = audioActiveCall ?? answeredCallAwaitingAudio else { return }
        cancelAudioActivationDeadline()
        if audioActiveCall == callUUID { audioActiveCall = nil }
        if answeredCallAwaitingAudio == callUUID { answeredCallAwaitingAudio = nil }
        onAudioSessionDeactivated?(audioSession, callUUID)
    }
}

extension SentiCallManager: @preconcurrency PKPushRegistryDelegate {
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = Self.hexToken(pushCredentials.token)
        onVoipToken?(token)
    }

    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        onVoipTokenInvalidated?()
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
        handleIncomingPushPayload(payload.dictionaryPayload, completion: completion)
    }

    /// Testable PushKit core. Completion is deliberately chained to the CallKit report callback, not to invocation
    /// of `reportNewIncomingCall`; this is the iOS 13+ delivery contract that prevents termination/VoIP throttling.
    func handleIncomingPushPayload(
        _ dict: [AnyHashable: Any],
        completion: @escaping () -> Void
    ) {
        replayCurrentVoipToken()
        let authorize = isIncomingBindingAuthorized ?? { _, _ in false }
        let prepared = Self.prepareIncomingPush(
            dict,
            isBindingAuthorized: authorize
        )
        ring(prepared.call) { [weak self] accepted in
            // Surface hydration state only after CallKit accepted the exact report. A failed or concurrently revoked
            // report retains no protected caller/session state and can never later be answered into a governed flow.
            if accepted {
                guard let state = prepared.state,
                      let dialId = prepared.dialId,
                      let rawFence = DeviceRingPushFenceParser.parse(dict),
                      authorize(rawFence.sessionId, rawFence.fence) else {
                    // CallKit accepted the mandatory report, but authority disappeared (or never existed) before the
                    // report completed. End that exact UUID immediately; it must not linger as an answerable episode.
                    self?.end(prepared.call.id)
                    completion()
                    return
                }
                self?.onDialReceived?(state, dialId, prepared.call.id)
            }
            completion()
        }
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
        isBindingAuthorized: (String, DeviceRingBindingFence) -> Bool
    ) -> (call: IncomingDecisionCall, state: DialReceiveState?, dialId: String?) {
        let generic = IncomingDecisionCall(
            id: UUID(),
            dialId: "",
            callerDisplayName: "Senti",
            message: "",
            context: nil,
            priority: "medium"
        )
        // Parse only v/session/binding, authorize, then permit the full DTO decoder to touch display/governed fields.
        guard let rawFence = DeviceRingPushFenceParser.parse(payload),
              isBindingAuthorized(rawFence.sessionId, rawFence.fence),
              let received = receiveState(from: payload),
              let stateFence = sessionAndFence(from: received.state),
              UTF8ExactIdentity.matches(stateFence.sessionId, rawFence.sessionId),
              stateFence.fence == rawFence.fence else {
            return (generic, nil, nil)
        }
        let decoded = decode(payload)
        return (decoded, received.state, received.dialId)
    }

    private static func sessionAndFence(
        from state: DialReceiveState
    ) -> (sessionId: String, fence: DeviceRingBindingFence)? {
        switch state {
        case .renderable(let ring):
            guard let binding = ring.core.binding else { return nil }
            return (ring.core.sessionId, binding)
        case .needsHydration(_, let core):
            guard let binding = core.binding else { return nil }
            return (core.sessionId, binding)
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
