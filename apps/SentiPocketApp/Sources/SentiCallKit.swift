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
// reads only what CallKit needs (id / who / priority) and ALWAYS yields a presentable call, so a malformed or partial
// push still RINGS (a delivery is never silently dropped) and the orchestrator re-validates the episode on answer.
#if canImport(CallKit) && canImport(PushKit)
import AVFoundation
import CallKit
import Foundation
import PushKit

/// The minimal incoming "decision call" the DialOrchestrator acts on. Mapping relay's /dial push payload → this type
/// is a separate adapter (relay owns the wire); SentiCallKit needs only an id + who is calling + an advisory priority.
public struct IncomingDecisionCall: Equatable, Sendable {
    public let id: UUID
    public let callerDisplayName: String
    public let priority: String   // "update" | "decision" | "urgent" — advisory (ring styling / UX only)
    public init(id: UUID, callerDisplayName: String, priority: String) {
        self.id = id
        self.callerDisplayName = callerDisplayName
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
    /// The call ended / was declined → tear down (stop audio, drop the episode).
    public var onEnded: ((UUID) -> Void)?
    /// CallKit ACTIVATED the audio session → safe to start capture/playback (hand to PocketVoice's DuplexAudioSessionLease).
    public var onAudioSessionActivated: ((AVAudioSession) -> Void)?

    private let provider: CXProvider
    private let pushRegistry: PKPushRegistry
    private var active: [UUID: IncomingDecisionCall] = [:]

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
        provider.reportNewIncomingCall(with: call.id, update: update, completion: { _ in })
    }

    /// Demo convenience: ring from the foreground with no VoIP cert — Carter sees the native call UI today.
    public func presentDemoRing(callerName: String = "Senti — decision needed", priority: String = "decision") {
        ring(IncomingDecisionCall(id: UUID(), callerDisplayName: callerName, priority: priority))
    }

    /// Programmatically end an active call (e.g., the governed writeback finished and we hang up).
    public func end(_ id: UUID) {
        provider.reportCall(with: id, endedAt: nil, reason: .remoteEnded)
        active[id] = nil
    }
}

extension SentiCallManager: @preconcurrency CXProviderDelegate {
    public func providerDidReset(_ provider: CXProvider) {
        active.removeAll()
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        if let call = active[action.callUUID] { onAnswered?(call) }
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        onEnded?(action.callUUID)
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
        // Report the incoming call (inside `ring`) BEFORE completion() — the iOS 13+ requirement.
        ring(Self.decode(payload.dictionaryPayload))
        completion()
    }

    /// Fail-safe decode: read only what CallKit needs and ALWAYS return a presentable call (a malformed push still
    /// rings — never a silently-dropped delivery). The orchestrator re-validates the full episode on answer.
    static func decode(_ payload: [AnyHashable: Any]) -> IncomingDecisionCall {
        let id = (payload["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        let name = (payload["from"] as? String)
            ?? (payload["message"] as? String)
            ?? "Senti — decision needed"
        let priority = (payload["priority"] as? String) ?? "decision"
        return IncomingDecisionCall(id: id, callerDisplayName: String(name.prefix(80)), priority: priority)
    }
}
#endif
