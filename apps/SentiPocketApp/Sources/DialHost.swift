#if canImport(CallKit) && canImport(PushKit)
import Foundation
import PocketCall
import PocketContracts
import PocketReasoning
import PocketDialVoice

// DialHost — the app-lifetime composition wiring for DIALS (Forge, onAnswered hookup part-b). With a trusted gateway
// configured, it owns SentiCallManager (its PKPushRegistry delegate must live the whole app) + DialCoordinator and
// installs the two adapters + three governed DI seams warden's part-b gate specifies:
//   • push-receive  → coordinator.received(state, dialId)         (adapter 1)
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
    private var registrar: DeviceRingRegistrar?
    private var selectedSessionId: String?
    private var latestVoipToken: String?
    private var authenticated = false
    private var activeDialTask: Task<Void, Never>?
    private var activeCallUUID: UUID?
    private var dialRevision: UInt64 = 0

    init(gatewayURL: URL? = DialHost.gatewayURL()) {
        let selectionGate = DialSessionSelectionGate()
        let installation = DeviceRingInstallationController.live
        let bindingGate = DeviceRingBindingGate(initialBinding: installation.loadCurrentBinding())
        let authenticationExpiry = AuthenticationExpiryRelay()
        self.selectionGate = selectionGate
        self.installation = installation
        self.bindingGate = bindingGate
        self.authenticationExpiry = authenticationExpiry
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
            runDial: { ring in
                guard DialDeviceAuthorization.permits(
                    ring.core,
                    selectionGate: selectionGate,
                    bindingGate: bindingGate
                ) else {
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
                        )
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
        cm.onDialReceived = { coord.received($0, dialId: $1) }
        // Adapter 2 — hydrate + run off the dialId + CallKit UUID ONLY; never off IncomingDecisionCall.message.
        cm.onAnswered = { [weak self] call in
            self?.answer(dialId: call.dialId, callUUID: call.id)
        }
        cm.onEnded = { [weak self] callUUID in
            self?.callEnded(callUUID)
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
        activeDialTask?.cancel()
        activeDialTask = nil
        activeCallUUID = nil
        dialRevision &+= 1
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
                    self.activeDialTask?.cancel()
                    self.activeDialTask = nil
                    self.activeCallUUID = nil
                    self.dialRevision &+= 1
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

    private func answer(dialId: String, callUUID: UUID) {
        guard selectedSessionId != nil, let coordinator else {
            callManager?.end(callUUID)
            return
        }
        activeDialTask?.cancel()
        dialRevision &+= 1
        let operationRevision = dialRevision
        activeCallUUID = callUUID
        activeDialTask = Task { @MainActor [weak self] in
            _ = await coordinator.answered(dialId: dialId, callUUID: callUUID)
            guard let self, self.dialRevision == operationRevision else { return }
            self.activeDialTask = nil
            if self.activeCallUUID == callUUID {
                self.activeCallUUID = nil
            }
        }
    }

    private func callEnded(_ callUUID: UUID) {
        guard activeCallUUID == callUUID else { return }
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
#endif
