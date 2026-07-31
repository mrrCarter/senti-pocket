#if canImport(CallKit) && canImport(PushKit)
import Foundation
import PocketCall
import PocketContracts
import PocketReasoning
import PocketDialVoice

// DialHost — the app-lifetime composition wiring for DIALS (Forge, onAnswered hookup part-b). With a trusted gateway
// configured, it owns SentiCallManager (its PKPushRegistry delegate must live the whole app) + DialCoordinator and
// installs the two adapters + three governed DI seams warden's part-b gate specifies:
//   • push-receive  → coordinator.received(state, dialId, UUID)   (adapter 1)
//   • answer        → coordinator.answered(dialId, callUUID)      (adapter 2)  — dialId+UUID only, never .message
//   • hydrate seam  = the AUTHED DialHydrationClient (governed content from the GET, never the push)
//   • runDial seam  = the governed LiveDialVoice + PhoneWriteAdapter + DialOrchestrator
//   • endCall seam  = SentiCallManager.end
//
// FOOTGUN-SAFE (warden's load-bearing gate): the write-driving content is ONLY ever the HYDRATED RenderableRing —
// the coordinator never receives IncomingDecisionCall, and `run` builds DialRequest from the hydrated ring's core,
// so the unauthenticated push fields can't reach the write by construction. `modelURL` comes from
// WhisperModelLocator.resolve() (option A, on-device Whisper); when the model isn't provisioned it resolves to nil
// → listen() degrades to "" → the orchestrator briefs but can't capture — nothing posts (the same fail-safe as before).
@MainActor
final class DialHost: ObservableObject {
    let callManager: SentiCallManager?
    private let coordinator: DialCoordinator?
    private let registrationClient: DeviceRingRegistrationClient?
    private let selectionGate: DialSessionSelectionGate
    private let bindingGate: DeviceRingBindingGate
    private let installation: DeviceRingInstallationController
    private let authenticationExpiry: AuthenticationExpiryRelay
    private let callAuthorizationGate: DialCallAuthorizationGate
    private var registrar: DeviceRingRegistrar?
    private var selectedSessionId: String?
    private var latestVoipToken: String?
    private var authenticated = false
    private var activeDialTask: Task<Void, Never>?
    private var activeCallUUID: UUID?
    private var dialRevision: UInt64 = 0
    private var callLifecycle = DialCallLifecycle()

    init(gatewayURL: URL? = DialHost.gatewayURL()) {
        let selectionGate = DialSessionSelectionGate()
        let installation = DeviceRingInstallationController.live
        let bindingGate = DeviceRingBindingGate(initialBinding: installation.loadCurrentBinding())
        let authenticationExpiry = AuthenticationExpiryRelay()
        let callAuthorizationGate = DialCallAuthorizationGate()
        self.selectionGate = selectionGate
        self.installation = installation
        self.bindingGate = bindingGate
        self.authenticationExpiry = authenticationExpiry
        self.callAuthorizationGate = callAuthorizationGate
        guard let gatewayURL else {
            // The default/unconfigured build does not start PushKit token acquisition or construct any gateway client.
            // A later configured launch builds the complete, app-lifetime call stack below.
            callManager = nil
            coordinator = nil
            registrationClient = nil
            registrar = nil
            return
        }

        let cm = SentiCallManager()
        let dialClient = DialHydrationClient(
            apiBaseURL: gatewayURL,
            onReauthenticationRequired: { authenticationExpiry.signal(expectedToken: $0) }
        )
        let selectedHydrator = SelectedSessionDialHydrator(
            selectionGate: selectionGate,
            isBindingAuthorized: { core in
                DialDeviceAuthorization.permitsBinding(
                    core,
                    bindingGate: bindingGate
                )
            },
            hydrate: dialClient.hydrate
        )
        let coord = DialCoordinator(
            hydrate: selectedHydrator.hydrate,
            runDial: { ring, callUUID in
                guard DialDeviceAuthorization.permits(
                    ring.core,
                    selectionGate: selectionGate,
                    bindingGate: bindingGate
                ), callAuthorizationGate.permits(callUUID) else {
                    return .declined("the selected session or device binding changed before the dial could run")
                }
                return await DialHost.run(
                    ring,
                    gatewayURL: gatewayURL,
                    onReauthenticationRequired: { authenticationExpiry.signal(expectedToken: $0) },
                    isWriteAuthorized: {
                        DialDeviceAuthorization.permits(
                            ring.core,
                            selectionGate: selectionGate,
                            bindingGate: bindingGate
                        ) && callAuthorizationGate.permits(callUUID)
                    }
                )
            },
            endCall: { [weak cm] uuid in cm?.end(uuid) }
        )

        self.callManager = cm
        self.coordinator = coord
        self.registrationClient = DeviceRingRegistrationClient(
            apiBaseURL: gatewayURL,
            onReauthenticationRequired: { authenticationExpiry.signal(expectedToken: $0) }
        )
        self.registrar = nil
        cm.isIncomingDialAuthorized = { core in
            DialDeviceAuthorization.permits(
                core,
                selectionGate: selectionGate,
                bindingGate: bindingGate
            )
        }
        // Adapter 1 — store the state decoded at push-receive (governed content fetched on answer).
        cm.onDialReceived = { [weak self] state, dialId, callUUID in
            self?.callReported(state: state, dialId: dialId, callUUID: callUUID)
        }
        // Adapter 2 — hydrate + run off the dialId + CallKit UUID ONLY; never off IncomingDecisionCall.message.
        cm.onAnswered = { [weak self] call in
            self?.answer(dialId: call.dialId, callUUID: call.id)
        }
        cm.onEnded = { [weak self] callUUID in
            self?.callEnded(callUUID)
        }
        cm.onAudioSessionActivated = { [weak self] _, callUUID in
            self?.callAudioActivated(callUUID)
        }
        cm.onAudioSessionDeactivated = { [weak self] _, callUUID in
            self?.callAudioDeactivated(callUUID)
        }
        // Adapter 3 — cache every APNs rotation. It is posted only after the authorized Sessions surface selects the
        // exact target and constructs that target's registrar.
        cm.onVoipToken = { [weak self] token in
            self?.voipTokenUpdated(token)
        }
        cm.onVoipTokenInvalidated = { [weak self] in
            self?.voipTokenInvalidated()
        }
    }

    /// Install the app's authentication-gate callback after the app-lifetime host and Release SignInCoordinator exist.
    func installAuthenticationExpiryHandler(
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) {
        authenticationExpiry.install { [weak self] in
            self?.onAuthenticationInvalidated()
            handler()
        }
    }

    /// Login alone never chooses a ring target. It merely arms registration for a later authorized selection.
    func onLoginCompleted() {
        authenticated = true
        _ = registrar?.loginCompleted()
    }

    /// Revoke all selected-session dial authority before the stale authenticated root is removed.
    func onAuthenticationInvalidated() {
        authenticated = false
        callManager?.revokeAllCalls()
        revokeDialExecutionAuthority()
        let hadRegistrar = registrar != nil
        selectSession(nil)
        if !hadRegistrar {
            _ = try? installation.beginRevocation(installation.loadCurrentBinding())
        }
        bindingGate.replace(with: nil)
    }

    /// Bind PushKit registration and dial hydration to the exact session selected from SessionListCoordinator's
    /// current authorized row allowlist. Nil or a selection change cancels the old in-flight flow and registrar.
    func selectSession(_ sessionId: String?) {
        guard selectedSessionId != sessionId else { return }

        selectionGate.select(nil)
        callManager?.revokeAllCalls()
        revokeDialExecutionAuthority()
        registrar?.invalidate()
        registrar = nil
        selectedSessionId = nil

        guard let sessionId,
              sessionId == sessionId.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty,
              sessionId.count <= 256,
              let registrationClient else { return }

        selectionGate.select(sessionId)
        selectedSessionId = sessionId
        let registrar = DeviceRingRegistrar(
            client: registrationClient,
            sessionId: sessionId,
            isLoggedIn: { [weak self] in
                self?.authenticated == true && SessionTokenStore.load() != nil
            },
            installation: installation,
            onBindingChanged: { [weak self] binding in
                guard let self else { return }
                self.bindingGate.replace(with: binding)
                if binding == nil {
                    self.callManager?.revokeAllCalls()
                    self.revokeDialExecutionAuthority()
                }
            }
        )
        self.registrar = registrar
        if let latestVoipToken {
            _ = registrar.tokenUpdated(latestVoipToken)
        }
    }

    private func voipTokenUpdated(_ token: String) {
        latestVoipToken = token
        _ = registrar?.tokenUpdated(token)
    }

    private func voipTokenInvalidated() {
        latestVoipToken = nil
        if let registrar {
            _ = registrar.tokenInvalidated()
        } else {
            _ = try? installation.beginRevocation(installation.loadCurrentBinding())
            bindingGate.replace(with: nil)
        }
    }

    private func callReported(state: DialReceiveState, dialId: String, callUUID: UUID) {
        guard let coordinator, callLifecycle.reported(callUUID: callUUID, dialId: dialId) else {
            coordinator?.discard(callUUID: callUUID)
            callManager?.end(callUUID)
            return
        }
        coordinator.received(state, dialId: dialId, callUUID: callUUID)
    }

    private func answer(dialId: String, callUUID: UUID) {
        guard selectedSessionId != nil, coordinator != nil else {
            callManager?.end(callUUID)
            return
        }
        dialRevision &+= 1
        let operationRevision = dialRevision
        activeCallUUID = callUUID
        let answerResult = callLifecycle.answered(
            callUUID: callUUID,
            dialId: dialId,
            revision: operationRevision
        )
        switch answerResult {
        case .rejected:
            callEnded(callUUID)
            callManager?.end(callUUID)
        case .waiting, .ready(_):
            do {
                // Configure play-and-record/voiceChat before SentiCallManager fulfills CXAnswerCallAction. CallKit,
                // not PocketVoice, remains the owner that activates/deactivates the session.
                try LiveDialVoice.prepareCallKitAudioSession()
            } catch {
                callEnded(callUUID)
                callManager?.end(callUUID)
                return
            }
            if case .ready(let ready) = answerResult {
                startDial(ready)
            }
        }
    }

    private func callAudioActivated(_ callUUID: UUID) {
        LiveDialVoice.callKitDidActivateAudioSession()
        if let ready = callLifecycle.audioActivated(callUUID: callUUID) {
            startDial(ready)
        }
    }

    private func callAudioDeactivated(_ callUUID: UUID) {
        LiveDialVoice.callKitDidDeactivateAudioSession()
        guard callLifecycle.audioDeactivated(callUUID: callUUID) != nil else { return }
        coordinator?.discard(callUUID: callUUID)
        callAuthorizationGate.close(callUUID)
        if activeCallUUID == callUUID {
            activeDialTask?.cancel()
            activeDialTask = nil
            activeCallUUID = nil
            dialRevision &+= 1
        }
        callManager?.end(callUUID)
    }

    private func startDial(_ ready: DialCallLifecycle.Ready) {
        guard dialRevision == ready.revision,
              selectedSessionId != nil,
              let coordinator,
              callLifecycle.isReported(ready.callUUID) else {
            callEnded(ready.callUUID)
            callManager?.end(ready.callUUID)
            return
        }
        activeDialTask?.cancel()
        callAuthorizationGate.open(ready.callUUID)
        activeCallUUID = ready.callUUID
        activeDialTask = Task { @MainActor [weak self] in
            _ = await coordinator.answered(dialId: ready.dialId, callUUID: ready.callUUID)
            guard let self, self.dialRevision == ready.revision else { return }
            self.callAuthorizationGate.close(ready.callUUID)
            _ = self.callLifecycle.ended(callUUID: ready.callUUID)
            self.activeDialTask = nil
            if self.activeCallUUID == ready.callUUID {
                self.activeCallUUID = nil
            }
        }
    }

    private func callEnded(_ callUUID: UUID) {
        coordinator?.discard(callUUID: callUUID)
        let ownedLifecycleEpisode = callLifecycle.ended(callUUID: callUUID) != nil
        callAuthorizationGate.close(callUUID)
        let ownedActiveTask = activeCallUUID == callUUID
        if ownedActiveTask {
            activeDialTask?.cancel()
            activeDialTask = nil
            activeCallUUID = nil
        }
        // A generic/stale CallKit UUID can end while another governed episode is alive. Only the UUID that actually
        // owned reported/pending/started lifecycle state or the active task may invalidate that task's revision.
        if ownedLifecycleEpisode || ownedActiveTask {
            dialRevision &+= 1
        }
    }

    private func revokeDialExecutionAuthority() {
        coordinator?.discardAll()
        callLifecycle.reset()
        callAuthorizationGate.closeAll()
        activeDialTask?.cancel()
        activeDialTask = nil
        activeCallUUID = nil
        dialRevision &+= 1
    }

    /// Build + run the governed flow for a HYDRATED ring. DialRequest is built from the ring's core (authed), NEVER
    /// the push. modelURL is resolved by WhisperModelLocator (App Support side-load / bundle); it nil-degrades
    /// (brief-only, no capture) when the model isn't provisioned — so a missing model never blocks a dial.
    static func run(
        _ ring: RenderableRing,
        gatewayURL: URL,
        onReauthenticationRequired: @escaping @Sendable (String?) -> Void = { _ in },
        isWriteAuthorized: @escaping @MainActor () -> Bool = { true }
    ) async -> DialOutcome {
        let reasoner = ProviderDialReasoner(
            provider: GatewayReasoningProvider(client: GatewayReasoningHTTPClient(
                apiBaseURL: gatewayURL,
                onReauthenticationRequired: onReauthenticationRequired
            )))
        let voice = LiveDialVoice(reasoner: reasoner,
                                  sessionId: ring.core.sessionId,
                                  checkpointId: ring.core.checkpointId,
                                  modelURL: WhisperModelLocator.resolve())
        let writeViewModel = PhoneWriteViewModel(
            sessionId: ring.core.sessionId,
            client: PocketWriteClient(apiBaseURL: gatewayURL),
            onReauthenticationRequired: onReauthenticationRequired,
            isWriteAuthorized: isWriteAuthorized
        )
        let writer = PhoneWriteAdapter(
            writeViewModel,
            isWriteAuthorized: isWriteAuthorized
        )
        let request = DialRequest(dialId: ring.core.id,
                                  // the AUTHED, hydrated governed content — with a pickOption ring's choices folded
                                  // into the spoken text so the pickup READS the options, not just the question (#17).
                                  message: dialSpokenMessage(message: ring.message, options: ring.options),
                                  callerName: ring.core.callerName,
                                  priority: ring.core.priority)
        return await DialOrchestrator(voice: voice, writer: writer).run(request)
    }

    /// `nonisolated` keeps the default argument usable off the main actor. Missing or invalid configuration is nil,
    /// so the initializer never creates the PushKit/CallKit stack or any gateway client.
    nonisolated static func gatewayURL() -> URL? {
        GatewayEndpoint.resolve(infoPlistKeys: ["SENTI_GATEWAY_URL"])
    }
}

enum DialHostError: LocalizedError {
    case sessionNotSelected

    var errorDescription: String? {
        "The ring does not belong to the currently selected authorized session."
    }
}

/// One reusable authorization expression for receive, post-hydration run, and every governed-write recheck. Keeping
/// selection and the exact Registry V2 proof composed prevents a same-session principal/binding ABA from reviving an
/// answered flow that was authorized under an older bearer.
enum DialDeviceAuthorization {
    static func permits(
        _ core: RingCore,
        selectionGate: DialSessionSelectionGate,
        bindingGate: DeviceRingBindingGate
    ) -> Bool {
        selectionGate.permits(core.sessionId) &&
        permitsBinding(core, bindingGate: bindingGate)
    }

    static func permitsBinding(
        _ core: RingCore,
        bindingGate: DeviceRingBindingGate
    ) -> Bool {
        bindingGate.permits(
            sessionId: core.sessionId,
            bindingVersion: core.bindingVersion,
            bindingId: core.bindingId,
            bindingRevision: core.bindingRevision,
            installationGeneration: core.installationGeneration
        )
    }
}

/// Reject an unselected push before the authenticated GET, then recheck after await to close selection TOCTOU.
@MainActor
final class SelectedSessionDialHydrator {
    private let selectionGate: DialSessionSelectionGate
    private let isBindingAuthorized: @MainActor (RingCore) -> Bool
    private let hydrateState: @MainActor (DialReceiveState) async throws -> RenderableRing

    init(
        selectionGate: DialSessionSelectionGate,
        isBindingAuthorized: @escaping @MainActor (RingCore) -> Bool = { _ in true },
        hydrate: @escaping @MainActor (DialReceiveState) async throws -> RenderableRing
    ) {
        self.selectionGate = selectionGate
        self.isBindingAuthorized = isBindingAuthorized
        self.hydrateState = hydrate
    }

    func hydrate(_ state: DialReceiveState) async throws -> RenderableRing {
        let incomingCore: RingCore
        switch state {
        case .renderable(let ring):
            incomingCore = ring.core
        case .needsHydration(_, let core):
            incomingCore = core
        case .rejected:
            throw DialHostError.sessionNotSelected
        }
        guard selectionGate.permits(incomingCore.sessionId),
              isBindingAuthorized(incomingCore) else {
            throw DialHostError.sessionNotSelected
        }

        let ring = try await hydrateState(state)
        guard selectionGate.permits(ring.core.sessionId),
              isBindingAuthorized(ring.core) else {
            throw DialHostError.sessionNotSelected
        }
        return ring
    }
}

/// Lock-backed because the hydration/provider closures are Sendable and may resume away from the main actor.
final class DialSessionSelectionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionId: String?

    func select(_ sessionId: String?) {
        lock.lock()
        self.sessionId = sessionId
        lock.unlock()
    }

    func permits(_ sessionId: String) -> Bool {
        lock.lock()
        let permitted = self.sessionId == sessionId
        lock.unlock()
        return permitted
    }
}

/// Main-actor episode reducer for the CallKit answer/audio handshake. A flow can start once, and only after the same
/// reported UUID has both an answer and a CallKit audio activation. End/reset/revoke/deactivate erase the episode, so
/// late callbacks are inert instead of reviving speech or a write path.
struct DialCallLifecycle {
    struct Ready: Equatable {
        let callUUID: UUID
        let dialId: String
        let revision: UInt64
    }

    enum AnswerResult: Equatable {
        case rejected
        case waiting
        case ready(Ready)
    }

    private var reported: [UUID: String] = [:]
    private var pendingAnswer: Ready?
    private var audioActivatedCallUUID: UUID?
    private var startedCallUUID: UUID?

    mutating func reported(callUUID: UUID, dialId: String) -> Bool {
        guard !dialId.isEmpty,
              reported[callUUID] == nil,
              reported.isEmpty else { return false }
        reported[callUUID] = dialId
        return true
    }

    mutating func answered(callUUID: UUID, dialId: String, revision: UInt64) -> AnswerResult {
        guard reported[callUUID] == dialId,
              startedCallUUID == nil,
              pendingAnswer == nil else { return .rejected }
        let ready = Ready(callUUID: callUUID, dialId: dialId, revision: revision)
        pendingAnswer = ready
        if let ready = takeReady() { return .ready(ready) }
        return .waiting
    }

    mutating func audioActivated(callUUID: UUID) -> Ready? {
        guard reported[callUUID] != nil,
              pendingAnswer?.callUUID == callUUID,
              startedCallUUID == nil else { return nil }
        audioActivatedCallUUID = callUUID
        return takeReady()
    }

    mutating func audioDeactivated(callUUID: UUID) -> UUID? {
        guard reported[callUUID] != nil,
              audioActivatedCallUUID == callUUID || pendingAnswer?.callUUID == callUUID else { return nil }
        _ = ended(callUUID: callUUID)
        return callUUID
    }

    @discardableResult
    mutating func ended(callUUID: UUID) -> String? {
        let dialId = reported.removeValue(forKey: callUUID)
        if pendingAnswer?.callUUID == callUUID { pendingAnswer = nil }
        if audioActivatedCallUUID == callUUID { audioActivatedCallUUID = nil }
        if startedCallUUID == callUUID { startedCallUUID = nil }
        return dialId
    }

    mutating func reset() {
        reported.removeAll()
        pendingAnswer = nil
        audioActivatedCallUUID = nil
        startedCallUUID = nil
    }

    func isReported(_ callUUID: UUID) -> Bool {
        reported[callUUID] != nil
    }

    private mutating func takeReady() -> Ready? {
        guard let pendingAnswer,
              audioActivatedCallUUID == pendingAnswer.callUUID,
              startedCallUUID == nil else { return nil }
        self.pendingAnswer = nil
        startedCallUUID = pendingAnswer.callUUID
        return pendingAnswer
    }
}

/// Synchronous write-time fence. Task cancellation is advisory; this lock-backed UUID gate is rechecked by every
/// draft/confirm request so End/Reset/auth/selection/binding/deactivation wins even if an async transcript resumes late.
final class DialCallAuthorizationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var liveCallUUIDs = Set<UUID>()

    func open(_ callUUID: UUID) {
        lock.lock()
        liveCallUUIDs.insert(callUUID)
        lock.unlock()
    }

    func close(_ callUUID: UUID) {
        lock.lock()
        liveCallUUIDs.remove(callUUID)
        lock.unlock()
    }

    func closeAll() {
        lock.lock()
        liveCallUUIDs.removeAll()
        lock.unlock()
    }

    func permits(_ callUUID: UUID) -> Bool {
        lock.lock()
        let permitted = liveCallUUIDs.contains(callUUID)
        lock.unlock()
        return permitted
    }
}
#endif
