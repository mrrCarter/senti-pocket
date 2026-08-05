#if canImport(CallKit) && canImport(PushKit)
import Combine
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
    /// CallKit/DialVoice is the exclusive audio owner from accepted ring through terminal teardown. Checkpoint
    /// narration observes this gate and is synchronously preempted before governed dial speech or capture can start.
    @Published private(set) var callAudioReservationIsActive = false

    let callManager: SentiCallManager?
    private let coordinator: DialCoordinator?
    private let registrar: DeviceRingRegistrar?
    private let bindingGate: DeviceRingBindingGate?
    private let registryStateStore: DeviceRingRegistryStateStore
    private let selectionGate: DialSessionSelectionGate
    private let authenticationExpiry: AuthenticationExpiryRelay
    private let callAuthorizationGate: DialCallAuthorizationGate
    private var selectedSessionId: String?
    private var authenticated = false
    private var activeDialTask: Task<Void, Never>?
    private var activeCallUUID: UUID?
    private var dialRevision: UInt64 = 0
    private var callLifecycle = DialCallLifecycle()
    /// Runtime observation only. Registry authority remains exclusively in DeviceRingRegistrar/secure state.
    private var observedVoipToken: String?
    private let prepareCallKitAudioSession: () throws -> Void
    private let callKitDidActivateAudioSession: () -> Void
    private let callKitDidDeactivateAudioSession: () -> Void
    private var preemptibleAudioRevoker: (
        id: UUID,
        revoke: @MainActor () -> Task<Void, Never>?
    )?
    private var preemptibleAudioStopBarrier: Task<Void, Never>?

    var permitsPreemptibleAudio: Bool { !callAudioReservationIsActive }

    init(
        gatewayURL: URL? = DialHost.gatewayURL(),
        registryStateStore: DeviceRingRegistryStateStore = DeviceRingRegistryStateStore()
    ) {
        let selectionGate = DialSessionSelectionGate()
        let authenticationExpiry = AuthenticationExpiryRelay()
        let callAuthorizationGate = DialCallAuthorizationGate()
        self.selectionGate = selectionGate
        self.authenticationExpiry = authenticationExpiry
        self.callAuthorizationGate = callAuthorizationGate
        self.registryStateStore = registryStateStore
        self.prepareCallKitAudioSession = { try LiveDialVoice.prepareCallKitAudioSession() }
        self.callKitDidActivateAudioSession = { LiveDialVoice.callKitDidActivateAudioSession() }
        self.callKitDidDeactivateAudioSession = { LiveDialVoice.callKitDidDeactivateAudioSession() }
        guard let gatewayURL else {
            // The default/unconfigured build does not start PushKit token acquisition or construct any gateway client.
            // A later configured launch builds the complete, app-lifetime call stack below.
            callManager = nil
            coordinator = nil
            registrar = nil
            bindingGate = nil
            return
        }

        let cm = SentiCallManager()
        let registryClient = DeviceRingRegistrationClient(
            apiBaseURL: gatewayURL,
            onReauthenticationRequired: { authenticationExpiry.signal(expectedToken: $0) }
        )
        let registrar = DeviceRingRegistrar(
            client: registryClient,
            stateStore: registryStateStore
        )
        let restoredSessionId = registryStateStore.restorableSelectedSessionId(
            credential: SessionTokenStore.load()
        )
        let bindingGate = DeviceRingBindingGate(
            stateStore: registryStateStore,
            voipTokenProvider: { [weak registrar] in registrar?.currentVoipToken },
            isSessionSelected: selectionGate.permits
        )
        let dialClient = DialHydrationClient(
            apiBaseURL: gatewayURL,
            onReauthenticationRequired: { authenticationExpiry.signal(expectedToken: $0) }
        )
        let selectedHydrator = SelectedSessionDialHydrator(
            selectionGate: selectionGate,
            bindingGate: bindingGate,
            hydrate: dialClient.hydrate
        )
        let coord = DialCoordinator(
            hydrate: selectedHydrator.hydrate,
            runDial: { ring, callUUID in
                guard let fence = ring.core.binding,
                      callAuthorizationGate.permits(callUUID),
                      bindingGate.permits(sessionId: ring.core.sessionId, fence: fence) else {
                    return .declined("the call audio or selected device binding changed before the dial could run")
                }
                return await DialHost.run(
                    ring,
                    gatewayURL: gatewayURL,
                    onReauthenticationRequired: { authenticationExpiry.signal(expectedToken: $0) },
                    isWriteAuthorized: {
                        callAuthorizationGate.permits(callUUID)
                            && bindingGate.permits(sessionId: ring.core.sessionId, fence: fence)
                    }
                )
            },
            endCall: { [weak cm] uuid in
                callAuthorizationGate.close(uuid)
                cm?.end(uuid)
            }
        )

        self.callManager = cm
        self.coordinator = coord
        self.registrar = registrar
        self.bindingGate = bindingGate
        if let restoredSessionId {
            selectionGate.select(restoredSessionId)
            selectedSessionId = restoredSessionId
            _ = registrar.selectSession(restoredSessionId)
        }
        registrar.onSessionAuthorizationRevoked = { [weak self] sessionId in
            self?.sessionAuthorizationRevoked(sessionId)
        }
        registrar.onBindingAuthorityInvalidated = { [weak self] in
            self?.bindingAuthorityInvalidated()
        }
        cm.isIncomingBindingAuthorized = { sessionId, fence in
            bindingGate.permits(sessionId: sessionId, fence: fence)
        }
        installCallLifecycle(on: cm, coordinator: coord)
        installVoipTokenLifecycle(on: cm)
    }

    /// Hermetic composition seam for the CallKit lifecycle tests. Production still uses the complete initializer above;
    /// this initializer deliberately omits registry/network construction and injects the already-governed coordinator.
    init(
        callManager: SentiCallManager,
        coordinator: DialCoordinator,
        selectedSessionId: String,
        registryStateStore: DeviceRingRegistryStateStore = DeviceRingRegistryStateStore(),
        prepareCallKitAudioSession: @escaping () throws -> Void = {},
        callKitDidActivateAudioSession: @escaping () -> Void = {},
        callKitDidDeactivateAudioSession: @escaping () -> Void = {}
    ) {
        let selectionGate = DialSessionSelectionGate()
        selectionGate.select(selectedSessionId)
        self.callManager = callManager
        self.coordinator = coordinator
        self.registrar = nil
        self.bindingGate = nil
        self.registryStateStore = registryStateStore
        self.selectionGate = selectionGate
        self.authenticationExpiry = AuthenticationExpiryRelay()
        self.callAuthorizationGate = DialCallAuthorizationGate()
        self.prepareCallKitAudioSession = prepareCallKitAudioSession
        self.callKitDidActivateAudioSession = callKitDidActivateAudioSession
        self.callKitDidDeactivateAudioSession = callKitDidDeactivateAudioSession
        self.selectedSessionId = selectedSessionId
        self.authenticated = true
        installCallLifecycle(on: callManager, coordinator: coordinator)
        installVoipTokenLifecycle(on: callManager)
    }

    private func installCallLifecycle(
        on callManager: SentiCallManager,
        coordinator: DialCoordinator
    ) {
        // Adapter 1 — admit one reported CallKit episode, then store its receive state under the exact UUID.
        callManager.onDialReceived = { [weak self] state, dialId, callUUID in
            self?.callReported(state: state, dialId: dialId, callUUID: callUUID)
        }
        // Adapter 2 — hydrate + run off the dialId + CallKit UUID ONLY; never off IncomingDecisionCall.message.
        callManager.onAnswered = { [weak self] call in
            self?.answer(dialId: call.dialId, callUUID: call.id)
        }
        callManager.onEnded = { [weak self] callUUID in
            self?.callEnded(callUUID)
        }
        callManager.onAudioSessionActivated = { [weak self] _, callUUID in
            self?.callKitAudioActivated(callUUID)
        }
        callManager.onAudioSessionDeactivated = { [weak self] _, callUUID in
            self?.callKitAudioDeactivated(callUUID)
        }
    }

    private func installVoipTokenLifecycle(on callManager: SentiCallManager) {
        // Cache every APNs rotation. It is posted only after the authorized Sessions surface selects the exact target
        // and constructs that target's registrar. A route change synchronously closes the old call plane.
        callManager.onVoipToken = { [weak self] token in
            self?.voipTokenUpdated(token)
        }
        callManager.onVoipTokenInvalidated = { [weak self] in
            self?.voipTokenInvalidated()
        }
        callManager.replayCurrentVoipToken()
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
        closeLocalAuthority()
        registrar?.authenticationInvalidated()
        selectedSessionId = nil
    }

    /// Synchronous sign-out half. This runs before SignInCoordinator.handle(.signOut) returns: runtime authority closes
    /// immediately and the registrar durably marks the old binding for revoke while the old bearer is still available.
    func beginSignOut() throws {
        closeLocalAuthority()
        selectedSessionId = nil
        if let registrar {
            try registrar.beginSignOut()
            return
        }
        // Configuration can disappear between releases while ThisDeviceOnly Keychain state survives. Never silently
        // delete the bearer if a disabled host cannot revoke that retained route; persist independent denial first.
        do {
            var state = try registryStateStore.load()
            guard !state.isEmpty else { return }
            try registryStateStore.denyAuthority()
            state.revocationRequested = true
            try registryStateStore.save(state)
        } catch {
            throw DeviceRingSignOutError.secureState
        }
    }

    /// Async sign-out half. Only a fully reconciled/empty Registry V2 state permits credential deletion. On failure the
    /// host stays internally authenticated solely so the exact revoke can retry; all selection/call gates remain closed.
    func prepareForSignOut() async throws {
        if let registrar {
            try await registrar.finishSignOut()
        } else {
            let state: DeviceRingRegistryState
            do {
                state = try registryStateStore.load()
            } catch {
                throw DeviceRingSignOutError.secureState
            }
            guard state.isEmpty else {
                throw DeviceRingSignOutError.revocationIncomplete
            }
        }
        authenticated = false
    }

    /// Bind PushKit registration and dial hydration to the exact session selected from SessionListCoordinator's
    /// current authorized row allowlist. Nil or a selection change cancels the old in-flight flow and registrar.
    func selectSession(_ sessionId: String?) {
        guard selectedSessionId != sessionId else { return }

        closeLocalAuthority()
        selectedSessionId = nil

        guard let sessionId,
              DeviceRingRegistryValidation.isCanonicalOpaque(
                sessionId,
                maximumUTF8Bytes: 128
              ) else {
            _ = registrar?.selectSession(nil)
            return
        }

        selectionGate.select(sessionId)
        selectedSessionId = sessionId
        _ = registrar?.selectSession(sessionId)
    }

    private func voipTokenUpdated(_ token: String) {
        let replacedExistingRoute = observedVoipToken.map { $0 != token } ?? false
        observedVoipToken = token
        // Mutate the registrar's token synchronously before CallKit teardown can re-enter receive authorization.
        _ = registrar?.tokenUpdated(token)
        if replacedExistingRoute {
            closeCallAuthorityPreservingSelection()
        }
    }

    private func voipTokenInvalidated() {
        observedVoipToken = nil
        // Clear the binding gate and persist denial before CallKit teardown invokes any external callbacks.
        _ = registrar?.tokenInvalidated()
        closeCallAuthorityPreservingSelection()
    }

    private func sessionAuthorizationRevoked(_ sessionId: String) {
        guard selectedSessionId == sessionId else { return }
        closeLocalAuthority()
        selectedSessionId = nil
    }

    /// Registry renewal/loss invalidates the old proof but preserves the user's selected target for re-registration.
    /// Internal so the lifecycle contract can be exercised without constructing the production network client.
    func bindingAuthorityInvalidated() {
        closeCallAuthorityPreservingSelection()
    }

    func applicationBecameActive() {
        _ = registrar?.applicationBecameActive()
    }

    /// Registers the currently visible, lower-priority audio owner. There is at most one verified checkpoint surface;
    /// replacement is intentional and exact-token removal prevents an old view from unregistering a newer one.
    func installPreemptibleAudioRevoker(
        _ revoke: @escaping @MainActor () -> Task<Void, Never>?
    ) -> UUID {
        if let previous = preemptibleAudioRevoker {
            queuePreemptibleAudioStop(previous.revoke())
        }
        let id = UUID()
        preemptibleAudioRevoker = (id: id, revoke: revoke)
        if callAudioReservationIsActive {
            queuePreemptibleAudioStop(revoke())
        }
        return id
    }

    func removePreemptibleAudioRevoker(_ id: UUID) {
        guard let revoker = preemptibleAudioRevoker, revoker.id == id else { return }
        queuePreemptibleAudioStop(revoker.revoke())
        preemptibleAudioRevoker = nil
    }

    private func closeLocalAuthority() {
        // Selection changes additionally close hydration and registration authority.
        selectionGate.select(nil)
        closeCallAuthorityPreservingSelection()
    }

    private func closeCallAuthorityPreservingSelection() {
        // Close every synchronous write fence before cancellation or CallKit teardown. Keep the selected session so a
        // replacement PushKit token can register the same authorized target; its binding gate stays closed until then.
        coordinator?.discardAll()
        callLifecycle.reset()
        callAuthorizationGate.closeAll()
        activeDialTask?.cancel()
        activeDialTask = nil
        activeCallUUID = nil
        dialRevision &+= 1
        releaseCallAudioReservation()
        callManager?.revokeAllCalls()
    }

    private func callReported(state: DialReceiveState, dialId: String, callUUID: UUID) {
        guard let coordinator, callLifecycle.reported(callUUID: callUUID, dialId: dialId) else {
            coordinator?.discard(callUUID: callUUID)
            callManager?.end(callUUID)
            return
        }
        reserveCallAudio()
        coordinator.received(state, dialId: dialId, callUUID: callUUID)
    }

    private func answer(dialId: String, callUUID: UUID) {
        guard selectedSessionId != nil, let coordinator else {
            self.coordinator?.discard(callUUID: callUUID)
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
            coordinator.discard(callUUID: callUUID)
            callEnded(callUUID)
            callManager?.end(callUUID)
        case .waiting, .ready(_):
            do {
                // Configure play-and-record/voiceChat before SentiCallManager fulfills CXAnswerCallAction. CallKit,
                // not PocketVoice, remains the owner that activates/deactivates the audio session.
                try prepareCallKitAudioSession()
            } catch {
                coordinator.discard(callUUID: callUUID)
                callEnded(callUUID)
                callManager?.end(callUUID)
                return
            }
            if case .ready(let ready) = answerResult {
                startDial(ready)
            }
        }
    }

    private func callKitAudioActivated(_ callUUID: UUID) {
        callKitDidActivateAudioSession()
        if let ready = callLifecycle.audioActivated(callUUID: callUUID) {
            startDial(ready)
        }
    }

    private func callKitAudioDeactivated(_ callUUID: UUID) {
        callKitDidDeactivateAudioSession()
        guard callLifecycle.audioDeactivated(callUUID: callUUID) != nil else { return }
        releaseCallAudioReservation()
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
        let audioStopBarrier = preemptibleAudioStopBarrier
        activeDialTask = Task { @MainActor [weak self] in
            if let audioStopBarrier { await audioStopBarrier.value }
            guard let self,
                  !Task.isCancelled,
                  self.dialRevision == ready.revision,
                  self.callAudioReservationIsActive,
                  self.activeCallUUID == ready.callUUID,
                  self.callAuthorizationGate.permits(ready.callUUID),
                  self.callLifecycle.isReported(ready.callUUID) else { return }
            _ = await coordinator.answered(
                dialId: ready.dialId,
                callUUID: ready.callUUID
            )
            guard self.dialRevision == ready.revision else { return }
            self.callAuthorizationGate.close(ready.callUUID)
            _ = self.callLifecycle.ended(callUUID: ready.callUUID)
            self.activeDialTask = nil
            if self.activeCallUUID == ready.callUUID {
                self.activeCallUUID = nil
            }
            self.releaseCallAudioReservation()
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
        // A stale UUID can end while another governed episode is live. Only an owned lifecycle episode/task advances
        // the revision and invalidates work; teardown for any other UUID is inert.
        if ownedLifecycleEpisode || ownedActiveTask {
            dialRevision &+= 1
            releaseCallAudioReservation()
        }
    }

    private func reserveCallAudio() {
        guard !callAudioReservationIsActive else { return }
        callAudioReservationIsActive = true
        queuePreemptibleAudioStop(preemptibleAudioRevoker?.revoke())
    }

    private func releaseCallAudioReservation() {
        callAudioReservationIsActive = false
    }

    private func queuePreemptibleAudioStop(_ stop: Task<Void, Never>?) {
        guard let stop else { return }
        let predecessor = preemptibleAudioStopBarrier
        let barrier = Task { @MainActor in
            if let predecessor { await predecessor.value }
            await stop.value
        }
        preemptibleAudioStopBarrier = barrier
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

/// Reject an unselected push before the authenticated GET, then recheck after await to close selection TOCTOU.
@MainActor
final class SelectedSessionDialHydrator {
    private let selectionGate: DialSessionSelectionGate
    private let isBindingAuthorized: @MainActor (String, DeviceRingBindingFence) -> Bool
    private let hydrateState: @MainActor (DialReceiveState) async throws -> RenderableRing

    init(
        selectionGate: DialSessionSelectionGate,
        bindingGate: DeviceRingBindingGate,
        hydrate: @escaping @MainActor (DialReceiveState) async throws -> RenderableRing
    ) {
        self.selectionGate = selectionGate
        self.isBindingAuthorized = bindingGate.permits
        self.hydrateState = hydrate
    }

    init(
        selectionGate: DialSessionSelectionGate,
        isBindingAuthorized: @escaping @MainActor (String, DeviceRingBindingFence) -> Bool,
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
        guard let incomingFence = incomingCore.binding,
              selectionGate.permits(incomingCore.sessionId),
              isBindingAuthorized(incomingCore.sessionId, incomingFence) else {
            throw DialHostError.sessionNotSelected
        }

        let ring = try await hydrateState(state)
        guard ring.core.sessionId == incomingCore.sessionId,
              ring.core.binding == incomingFence,
              selectionGate.permits(ring.core.sessionId),
              isBindingAuthorized(ring.core.sessionId, incomingFence) else {
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
