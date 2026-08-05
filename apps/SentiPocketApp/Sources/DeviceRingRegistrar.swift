// DeviceRingRegistrar — main-actor lifecycle driver for installation-owned Registry V2.
//
// Registration starts only with all three authorities present: a PushKit token, a session bearer, and an exact selected
// member session. The installation controller persists a pending monotonic generation before the request. A successful
// server proof is committed only if this registrar revision, token, selection, and bearer are still current.
//
// Revocation is synchronous locally: the Keychain record advances generation and clears the accepted proof before a
// best-effort compare-delete is launched with the still-captured bearer. TTL and the higher next generation preserve
// safety even if cleanup never reaches the server.

import Foundation

@MainActor
final class DeviceRingRegistrar {
    private let client: DeviceRingRegistrationClient
    private let sessionId: String
    private let isLoggedIn: () -> Bool
    private let installation: DeviceRingInstallationController
    private let onBindingChanged: (DeviceRingBinding?) -> Void

    private var latestToken: String?
    private var currentBinding: DeviceRingBinding?
    private var inFlight: Task<Void, Never>?
    private var operationRevision: UInt64 = 0

    init(
        client: DeviceRingRegistrationClient,
        sessionId: String,
        isLoggedIn: @escaping () -> Bool = { SessionTokenStore.load() != nil },
        installation: DeviceRingInstallationController = .live,
        onBindingChanged: @escaping (DeviceRingBinding?) -> Void = { _ in }
    ) {
        self.client = client
        self.sessionId = sessionId
        self.isLoggedIn = isLoggedIn
        self.installation = installation
        self.onBindingChanged = onBindingChanged
        if let stored = installation.loadCurrentBinding(), stored.sessionId == sessionId {
            currentBinding = stored
        }
    }

    @discardableResult
    func tokenUpdated(_ token: String) -> Task<Void, Never>? {
        guard !token.isEmpty else { return tokenInvalidated() }
        if let previous = latestToken, previous != token {
            revokeCurrentAuthority(clearToken: false)
        }
        latestToken = token
        return registerIfReady()
    }

    @discardableResult
    func tokenInvalidated() -> Task<Void, Never>? {
        revokeCurrentAuthority(clearToken: true)
        return nil
    }

    @discardableResult
    func loginCompleted() -> Task<Void, Never>? {
        registerIfReady()
    }

    @discardableResult
    func registerIfReady() -> Task<Void, Never>? {
        guard let token = latestToken, !token.isEmpty, isLoggedIn() else { return nil }
        let initialAttempt: DeviceRingRegistrationAttempt
        do {
            initialAttempt = try installation.beginRegistration(sessionId, token, false)
        } catch {
            revokeCurrentAuthority(clearToken: false)
            return nil
        }

        inFlight?.cancel()
        operationRevision &+= 1
        let expectedRevision = operationRevision
        // beginRegistration has already cleared the Keychain proof. Mirror that transition into the live PushKit gate
        // before any network suspension so an old lease cannot authorize a call while renewal/recovery is uncertain.
        currentBinding = nil
        onBindingChanged(nil)
        let client = self.client
        let installation = self.installation
        let sessionId = self.sessionId
        let task = Task { @MainActor [weak self] in
            var attempt = initialAttempt
            var canRecoverStaleGeneration = true
            while true {
                do {
                    let binding = try await client.register(
                        voipToken: token,
                        sessionId: sessionId,
                        attempt: attempt
                    )
                    guard let self,
                          !Task.isCancelled,
                          self.operationRevision == expectedRevision,
                          self.latestToken == token,
                          self.isLoggedIn() else { return }
                    do {
                        try installation.commitRegistration(attempt, binding)
                    } catch {
                        // The server may now have a lease, but a proof that could not be persisted must never be accepted.
                        self.revokeReturnedBinding(binding)
                        return
                    }
                    self.currentBinding = binding
                    self.onBindingChanged(binding)
                    if self.operationRevision == expectedRevision {
                        self.inFlight = nil
                    }
                    return
                } catch DeviceRingRegistrationError.bindingConflict where canRecoverStaleGeneration {
                    guard let self,
                          !Task.isCancelled,
                          self.operationRevision == expectedRevision,
                          self.latestToken == token,
                          self.isLoggedIn() else { return }
                    // One forced generation bump repairs an interrupted transition without allowing an unbounded 409
                    // loop. Capacity conflicts are a separate error and never enter this recovery path.
                    do {
                        attempt = try installation.beginRegistration(sessionId, token, true)
                    } catch {
                        self.revokeCurrentAuthority(clearToken: false)
                        return
                    }
                    self.currentBinding = nil
                    self.onBindingChanged(nil)
                    canRecoverStaleGeneration = false
                } catch {
                    guard let self, self.operationRevision == expectedRevision else { return }
                    self.inFlight = nil
                    // Pending identity state deliberately remains for an exact retry. 401 handling is owned by the
                    // client; auth/selection callbacks synchronously call invalidate(), advance generation, and clear
                    // authority.
                    return
                }
            }
        }
        inFlight = task
        return task
    }

    /// Authentication or selected-session authority disappeared. This executes before SessionTokenStore.delete().
    func invalidate() {
        revokeCurrentAuthority(clearToken: true)
    }

    private func revokeReturnedBinding(_ binding: DeviceRingBinding) {
        let cleanup: DeviceRingUnregistrationAttempt?
        do { cleanup = try installation.beginRevocation(binding) }
        catch { cleanup = nil }
        currentBinding = nil
        onBindingChanged(nil)
        if let cleanup { startCleanup(cleanup) }
    }

    private func revokeCurrentAuthority(clearToken: Bool) {
        inFlight?.cancel()
        inFlight = nil
        operationRevision &+= 1
        let stored = installation.loadCurrentBinding()
        let binding = currentBinding ?? (stored?.sessionId == sessionId ? stored : nil)
        let cleanup: DeviceRingUnregistrationAttempt?
        do { cleanup = try installation.beginRevocation(binding) }
        catch { cleanup = nil }
        currentBinding = nil
        onBindingChanged(nil)
        if clearToken { latestToken = nil }
        if let cleanup { startCleanup(cleanup) }
    }

    private func startCleanup(_ attempt: DeviceRingUnregistrationAttempt) {
        guard let network = client.beginUnregister(attempt) else { return }
        let installation = self.installation
        Task {
            if await network.value {
                try? installation.completeUnregistration(attempt)
            }
        }
    }

    deinit {
        inFlight?.cancel()
        // Cleanup tasks are intentionally not retained/cancelled: compare-delete remains safe after this registrar dies.
    }
}
