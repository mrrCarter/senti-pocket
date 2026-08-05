import Foundation

enum DeviceRingSignOutError: Error, Equatable, Sendable {
    case secureState
    case revocationIncomplete
}

/// App-lifetime Registry V2 state machine. Exactly one network operation runs at a time. Cancellation is not treated
/// as a correctness primitive: every response is compared with the persisted pending operation, current credential,
/// current token, selected session, and generation before it can cause a retry or authorize anything.
@MainActor
final class DeviceRingRegistrar {
    private enum ReconcileResult {
        case stop
        case continueImmediately
        case retryAfterBackoff
    }

    private struct ResolvedOwnerContextCache {
        let credentialFingerprint: String
        let generation: UInt64
        let context: DeviceRingRegistryOwnerContext
    }

    private let client: any DeviceRingRegistryClient
    private let installationStore: DeviceInstallationIdentityStore
    private let stateStore: DeviceRingRegistryStateStore
    private let bearerProvider: () -> String?
    private let now: () -> Date
    private let continuousNow: () -> TimeInterval?
    private let makeIdempotencyKey: () -> String
    private let retryDelay: (Int) async -> Void
    private let renewalWindow: TimeInterval

    private var latestToken: String?
    private var selectedSessionId: String?
    private var authenticated = false
    private var revokeBeforeNextRegistration = false
    private var generation: UInt64 = 0
    private var reconcileRequested = false
    private var worker: Task<Void, Never>?
    private var resolvedOwnerContextCache: ResolvedOwnerContextCache?

    /// A target-level 403 means the previously selected session is no longer authorized. DialHost installs this
    /// callback to synchronously close its independent selection/call gates; the durable pending record remains too.
    var onSessionAuthorizationRevoked: ((String) -> Void)?
    /// Reconciliation is about to replace or renew an existing binding. The old fence becomes non-permitting as soon
    /// as the pending operation is durable, so active call/write authority must close before registration continues.
    var onBindingAuthorityInvalidated: (() -> Void)?

    init(
        client: any DeviceRingRegistryClient,
        installationStore: DeviceInstallationIdentityStore = DeviceInstallationIdentityStore(),
        stateStore: DeviceRingRegistryStateStore = DeviceRingRegistryStateStore(),
        bearerProvider: @escaping () -> String? = { SessionTokenStore.load() },
        now: @escaping () -> Date = Date.init,
        continuousNow: @escaping () -> TimeInterval? = DeviceRingContinuousClock.now,
        makeIdempotencyKey: @escaping () -> String = { UUID().uuidString.lowercased() },
        retryDelay: @escaping (Int) async -> Void = { attempt in
            let milliseconds = min(100 * (1 << min(attempt, 5)), 2_000)
            try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
        },
        renewalWindow: TimeInterval = 2 * 24 * 60 * 60
    ) {
        self.client = client
        self.installationStore = installationStore
        self.stateStore = stateStore
        self.bearerProvider = bearerProvider
        self.now = now
        self.continuousNow = continuousNow
        self.makeIdempotencyKey = makeIdempotencyKey
        self.retryDelay = retryDelay
        self.renewalWindow = renewalWindow
    }

    var currentVoipToken: String? { latestToken }

    @discardableResult
    func tokenUpdated(_ token: String) -> Task<Void, Never>? {
        guard DeviceRingRegistryValidation.isCanonicalOpaque(token, maximumUTF8Bytes: 512) else {
            return tokenInvalidated()
        }
        if latestToken != token {
            latestToken = token
            generation &+= 1
            // A fresh token can atomically replace the invalidated route with POST. If an older POST was ambiguous,
            // the new semantic operation discovers its exact server fence through binding-conflict before transfer.
            if selectedSessionId != nil {
                revokeBeforeNextRegistration = false
            }
        }
        return scheduleReconciliation()
    }

    /// PushKit invalidated the route. Close the runtime gate synchronously, retain the exact server fence durably,
    /// then compare-delete it with the current bearer. The selected session remains desired for a later fresh token.
    @discardableResult
    func tokenInvalidated() -> Task<Void, Never>? {
        latestToken = nil
        generation &+= 1
        // Persist this even before login composition finishes. A killed launch can restore a clean credential-bound
        // route before `loginCompleted`; losing the PushKit token in that window must survive another process death.
        revokeBeforeNextRegistration = true
        markRevocationRequested()
        return scheduleReconciliation()
    }

    @discardableResult
    func loginCompleted() -> Task<Void, Never>? {
        authenticated = true
        generation &+= 1
        return scheduleReconciliation()
    }

    /// A rejected bearer cannot safely revoke: close authority now and retain the server tuple for a later exact
    /// transfer/reconciliation. No network request is started under the rejected credential.
    func authenticationInvalidated() {
        authenticated = false
        resolvedOwnerContextCache = nil
        selectedSessionId = nil
        revokeBeforeNextRegistration = false
        generation &+= 1
        markRevocationRequested()
        reconcileRequested = false
    }

    @discardableResult
    func selectSession(_ sessionId: String?) -> Task<Void, Never>? {
        let canonical = sessionId.flatMap {
            DeviceRingRegistryValidation.isCanonicalOpaque($0, maximumUTF8Bytes: 128) ? $0 : nil
        }
        guard selectedSessionId != canonical else {
            return scheduleReconciliation()
        }
        selectedSessionId = canonical
        generation &+= 1
        if canonical == nil {
            // Persist pre-login too: a killed-launch binding can be locally restorable before composition calls
            // loginCompleted, and an explicit deselection in that window must survive another process death.
            revokeBeforeNextRegistration = true
            markRevocationRequested()
        } else if canonical != nil {
            // A new target is transferred atomically by POST using the last exact binding fence.
            revokeBeforeNextRegistration = false
        }
        return scheduleReconciliation()
    }

    @discardableResult
    func applicationBecameActive() -> Task<Void, Never>? {
        guard authenticated else { return nil }
        return scheduleReconciliation()
    }

    /// Synchronous half of user sign-out. DialHost closes its in-memory gates before calling this. Persisting the
    /// marker before returning removes the scheduling window where a push could regain authority while sign-out waits
    /// to run. Failure is surfaced so the bearer is retained for a user retry.
    func beginSignOut() throws {
        guard authenticated else { return }
        selectedSessionId = nil
        revokeBeforeNextRegistration = true
        generation &+= 1
        do {
            try persistRevocationRequested()
        } catch {
            throw DeviceRingSignOutError.secureState
        }
    }

    /// Asynchronous half of user sign-out. It barriers/deletes any ambiguous POST through the digest-only cleanup route,
    /// then exact-deletes an independently persisted older binding. The registrar becomes unauthenticated only after
    /// durable state is empty; otherwise the old bearer remains usable while every local authorization gate stays closed.
    func finishSignOut() async throws {
        await scheduleReconciliation()?.value

        let state: DeviceRingRegistryState
        do {
            state = try stateStore.load()
        } catch {
            throw DeviceRingSignOutError.secureState
        }
        guard state.isEmpty else {
            throw DeviceRingSignOutError.revocationIncomplete
        }

        authenticated = false
        resolvedOwnerContextCache = nil
        revokeBeforeNextRegistration = false
        generation &+= 1
    }

    func revokeBeforeSignOut() async throws {
        try beginSignOut()
        try await finishSignOut()
    }

    private func markRevocationRequested() {
        try? persistRevocationRequested(requireEnvelopeMarker: false)
    }

    private func persistRevocationRequested(requireEnvelopeMarker: Bool = true) throws {
        // Attempt both independent closure channels. A file-marker failure must not prevent the Keychain envelope from
        // being marked, and a Keychain failure remains fail-closed behind a successfully written independent marker.
        var independentDenialSucceeded = false
        do {
            try stateStore.denyAuthority()
            independentDenialSucceeded = true
        } catch {
            // Continue into the independent Keychain attempt below.
        }

        do {
            var state = try stateStore.load()
            guard state.binding != nil || state.pendingRegistration != nil else { return }
            state.revocationRequested = true
            try stateStore.save(state)
        } catch {
            if requireEnvelopeMarker || !independentDenialSucceeded {
                throw error
            }
        }
    }

    @discardableResult
    private func scheduleReconciliation() -> Task<Void, Never>? {
        reconcileRequested = true
        if let worker { return worker }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drain()
        }
        worker = task
        return task
    }

    private func drain() async {
        var immediateRetries = 0
        while reconcileRequested {
            reconcileRequested = false
            let result = await reconcileOnce()
            switch result {
            case .stop:
                break
            case .continueImmediately:
                immediateRetries += 1
                if immediateRetries <= 4 {
                    reconcileRequested = true
                }
            case .retryAfterBackoff:
                immediateRetries += 1
                if immediateRetries <= 3 {
                    await retryDelay(immediateRetries)
                    reconcileRequested = true
                }
            }
        }
        worker = nil
        if reconcileRequested {
            _ = scheduleReconciliation()
        }
    }

    /// Resolve the stable server-authenticated registry owner under the exact bearer captured for this reconciliation.
    /// The handle is pseudonymous, not authority; every mutation still carries the bearer and the server recomputes it.
    private func resolveOwnerContext(
        bearer: String,
        credentialFingerprint: String,
        operationGeneration: UInt64
    ) async -> DeviceRingRegistryOwnerContext? {
        if let cached = resolvedOwnerContextCache,
           cached.credentialFingerprint == credentialFingerprint,
           cached.generation == operationGeneration {
            return cached.context
        }
        do {
            let context = try await client.ownerContext(bearerToken: bearer)
            guard authenticated,
                  generation == operationGeneration,
                  bearerProvider() == bearer,
                  DeviceRingFingerprint.digest(bearer) == credentialFingerprint,
                  context.ownerVersion == DeviceRingRegistryOwnerContext.version,
                  DeviceRingFingerprint.isDigest(context.ownerHandle),
                  context.serverTime.timeIntervalSince1970.isFinite,
                  context.serverTime.timeIntervalSince1970 > 0 else {
                return nil
            }
            resolvedOwnerContextCache = ResolvedOwnerContextCache(
                credentialFingerprint: credentialFingerprint,
                generation: operationGeneration,
                context: context
            )
            return context
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
    }

    private func reconcileOnce() async -> ReconcileResult {
        guard authenticated,
              let bearer = bearerProvider(), !bearer.isEmpty else { return .stop }
        let credentialFingerprint = DeviceRingFingerprint.digest(bearer)
        let operationGeneration = generation
        guard let ownerContext = await resolveOwnerContext(
            bearer: bearer,
            credentialFingerprint: credentialFingerprint,
            operationGeneration: operationGeneration
        ) else { return .stop }
        do {
            try stateStore.completeOwnerContinuityCutover()
        } catch {
            return .stop
        }
        guard var state = try? stateStore.load() else { return .stop }
        guard [state.binding.map { ($0.ownerVersion, $0.ownerHandle) },
               state.pendingRegistration.map { ($0.ownerVersion, $0.ownerHandle) }]
            .compactMap({ $0 })
            .allSatisfy({ $0.0 == ownerContext.ownerVersion && $0.1 == ownerContext.ownerHandle }) else {
            // Different authenticated accounts cannot mutate, replace, or falsely clean persisted registry authority.
            return .stop
        }
        let authorityIsDenied = stateStore.authorityIsDenied()

        if revokeBeforeNextRegistration ||
            ((state.revocationRequested || authorityIsDenied) && selectedSessionId == nil) {
            return await reconcileRevocation(
                state: state,
                bearer: bearer,
                ownerContext: ownerContext,
                operationGeneration: operationGeneration
            )
        }

        guard let sessionId = selectedSessionId,
              let token = latestToken,
              DeviceRingRegistryValidation.isCanonicalOpaque(token, maximumUTF8Bytes: 512) else {
            return .stop
        }
        let tokenDigest = DeviceRingFingerprint.digest(token)

        if state.pendingRegistration == nil,
           !state.revocationRequested,
           !authorityIsDenied,
           let binding = state.binding,
           binding.sessionId == sessionId,
           binding.platform == "apns",
           binding.tokenDigest == tokenDigest,
           binding.credentialFingerprint == credentialFingerprint,
           binding.ownerVersion == ownerContext.ownerVersion,
           binding.ownerHandle == ownerContext.ownerHandle,
           let remainingLease = binding.remainingLease(
            wallNow: now(),
            continuousNow: continuousNow()
           ),
           remainingLease > renewalWindow {
            return .stop
        }

        let installationId: String
        do {
            if state.isEmpty {
                installationId = try installationStore.loadOrCreate()
            } else {
                guard let existing = try installationStore.load() else { return .stop }
                installationId = existing
            }
        } catch {
            return .stop
        }

        let existingMatchesIntent = state.pendingRegistration?.matches(
            sessionId: sessionId,
            platform: "apns",
            tokenDigest: tokenDigest,
            credentialFingerprint: credentialFingerprint,
            ownerVersion: ownerContext.ownerVersion,
            ownerHandle: ownerContext.ownerHandle
        ) ?? false
        if let existing = state.pendingRegistration, !existingMatchesIntent {
            // Never overwrite an ambiguous operation. Barrier/delete it first; otherwise a late A commit can become an
            // unaddressable zombie after B replaces A's only persisted idempotency key.
            guard existing.ownerVersion == ownerContext.ownerVersion,
                  existing.ownerHandle == ownerContext.ownerHandle,
                  markPendingForRevocationRecovery(existing) else {
                return .stop
            }
            return await cleanupPendingRegistration(
                pending: existing,
                installationId: installationId,
                bearer: bearer,
                operationGeneration: operationGeneration
            )
        }

        var pending: DeviceRingPendingRegistration
        if let existing = state.pendingRegistration, existingMatchesIntent {
            pending = existing
        } else {
            let invalidatesExistingBinding = state.binding != nil
            pending = DeviceRingPendingRegistration(
                sessionId: sessionId,
                platform: "apns",
                tokenDigest: tokenDigest,
                credentialFingerprint: credentialFingerprint,
                ownerVersion: ownerContext.ownerVersion,
                ownerHandle: ownerContext.ownerHandle,
                idempotencyKey: makeIdempotencyKey(),
                // Every distinct operation carries the last exact binding fence, including a same-intent renewal.
                // Only a replay of this persisted idempotency key may renew in place without another CAS decision.
                expectedBindingId: state.binding?.bindingId,
                expectedBindingRevision: state.binding?.bindingRevision,
                expectedTokenClaimId: nil,
                expectedTokenClaimRevision: nil
            )
            state.pendingRegistration = pending
            do {
                try stateStore.save(state)
            } catch {
                return .stop
            }
            if invalidatesExistingBinding {
                // The pending record is now durable and DeviceRingBindingGate is already closed before this callback
                // can re-enter CallKit or receive authorization.
                onBindingAuthorityInvalidated?()
            }
        }

        return await performRegistration(
            pending: pending,
            installationId: installationId,
            voipToken: token,
            bearer: bearer,
            operationGeneration: operationGeneration
        )
    }

    private func reconcileRevocation(
        state: DeviceRingRegistryState,
        bearer: String,
        ownerContext: DeviceRingRegistryOwnerContext,
        operationGeneration: UInt64
    ) async -> ReconcileResult {
        let installationId: String
        do {
            guard let existing = try installationStore.load() else { return .stop }
            installationId = existing
        } catch {
            return .stop
        }

        // A failed transport may have committed this POST. The digest-only cleanup endpoint races a terminal DENIED
        // barrier against that exact operation and compare-deletes its committed fence without needing the raw token.
        if let pending = state.pendingRegistration {
            guard pending.ownerVersion == ownerContext.ownerVersion,
                  pending.ownerHandle == ownerContext.ownerHandle else {
                return .stop
            }
            return await cleanupPendingRegistration(
                pending: pending,
                installationId: installationId,
                bearer: bearer,
                operationGeneration: operationGeneration
            )
        }

        guard let binding = state.binding else {
            // Nothing remains to compare-delete. Avoid persisting an impossible marker-only state.
            if state.revocationRequested {
                try? stateStore.save(DeviceRingRegistryState())
            }
            try? stateStore.clearAuthorityDenial()
            revokeBeforeNextRegistration = false
            return .stop
        }
        guard binding.ownerVersion == ownerContext.ownerVersion,
              binding.ownerHandle == ownerContext.ownerHandle else {
            return .stop
        }

        var marked = state
        if !marked.revocationRequested {
            marked.revocationRequested = true
            do {
                try stateStore.save(marked)
            } catch {
                return .stop
            }
        }

        let request = DeviceRingUnregistrationRequest(
            ownerHandle: binding.ownerHandle,
            installationId: installationId,
            sessionId: binding.sessionId,
            bindingId: binding.bindingId,
            bindingRevision: binding.bindingRevision
        )
        do {
            try await client.unregister(request, bearerToken: bearer)
            guard generation == operationGeneration,
                  bearerProvider() == bearer,
                  let current = try? stateStore.load(),
                  current.binding == binding,
                  current.pendingRegistration == nil,
                  current.revocationRequested else {
                return .stop
            }
            do {
                try stateStore.save(DeviceRingRegistryState())
            } catch {
                return .stop
            }
            do {
                try stateStore.clearAuthorityDenial()
            } catch {
                // The server route is gone and Keychain state is empty. Retaining a conservative local deny marker is
                // safer than reopening; a later explicit registration will retry clearing it.
            }
            revokeBeforeNextRegistration = false
            return selectedSessionId == nil ? .stop : .continueImmediately
        } catch is CancellationError {
            return .stop
        } catch {
            // 401/403/5xx/network/malformed all retain the exact tuple and durable revocation marker.
            return .stop
        }
    }

    private func cleanupPendingRegistration(
        pending: DeviceRingPendingRegistration,
        installationId: String,
        bearer: String,
        operationGeneration: UInt64
    ) async -> ReconcileResult {
        let request = DeviceRingRegistrationCleanupRequest(
            ownerHandle: pending.ownerHandle,
            installationId: installationId,
            idempotencyKey: pending.idempotencyKey,
            tokenDigest: pending.tokenDigest,
            sessionId: pending.sessionId,
            platform: pending.platform
        )
        do {
            try await client.cleanupRegistration(request, bearerToken: bearer)
            guard generation == operationGeneration,
                  bearerProvider() == bearer,
                  var current = try? stateStore.load(),
                  current.pendingRegistration == pending,
                  current.revocationRequested || revokeBeforeNextRegistration else {
                return .stop
            }

            current.pendingRegistration = nil
            current.revocationRequested = current.binding != nil
            do {
                try stateStore.save(current)
            } catch {
                // The exact pending operation remains durable because the atomic state update failed.
                return .stop
            }

            if current.binding != nil {
                // Cleanup addressed only the pending operation. Preserve and separately compare-delete any older fence.
                return .continueImmediately
            }
            do {
                try stateStore.clearAuthorityDenial()
            } catch {
                // Server cleanup is complete and state is empty; keeping the independent marker denied is conservative.
            }
            revokeBeforeNextRegistration = false
            return selectedSessionId == nil ? .stop : .continueImmediately
        } catch is CancellationError {
            return .stop
        } catch {
            // Every non-success keeps the exact digest tuple and durable denial marker for an identical retry.
            return .stop
        }
    }

    private func performRegistration(
        pending: DeviceRingPendingRegistration,
        installationId: String,
        voipToken: String,
        bearer: String,
        operationGeneration: UInt64
    ) async -> ReconcileResult {
        let request = DeviceRingRegistrationRequest(
            ownerHandle: pending.ownerHandle,
            installationId: installationId,
            idempotencyKey: pending.idempotencyKey,
            voipToken: voipToken,
            sessionId: pending.sessionId,
            platform: pending.platform,
            expectedBindingId: pending.expectedBindingId,
            expectedBindingRevision: pending.expectedBindingRevision,
            expectedTokenClaimId: pending.expectedTokenClaimId,
            expectedTokenClaimRevision: pending.expectedTokenClaimRevision
        )
        do {
            let receipt = try await client.register(request, bearerToken: bearer)
            guard authenticated,
                  generation == operationGeneration,
                  bearerProvider() == bearer,
                  pending.credentialFingerprint == DeviceRingFingerprint.digest(bearer),
                  receipt.ownerVersion == pending.ownerVersion,
                  receipt.ownerHandle == pending.ownerHandle,
                  receipt.sessionId == pending.sessionId,
                  receipt.platform == pending.platform,
                  var current = try? stateStore.load(),
                  current.pendingRegistration == pending else {
                return .stop
            }
            current.binding = DeviceRingBindingRecord(
                sessionId: pending.sessionId,
                platform: pending.platform,
                tokenDigest: pending.tokenDigest,
                credentialFingerprint: pending.credentialFingerprint,
                ownerVersion: receipt.ownerVersion,
                ownerHandle: receipt.ownerHandle,
                bindingId: receipt.bindingId,
                bindingRevision: receipt.bindingRevision,
                tokenClaimId: receipt.tokenClaimId,
                tokenClaimRevision: receipt.tokenClaimRevision,
                expiresAt: receipt.expiresAt,
                leaseAuthority: DeviceRingLeaseAuthority(
                    serverTime: receipt.serverTime,
                    wallTimeAtReceipt: receipt.wallTimeAtReceipt,
                    continuousTimeAtReceipt: receipt.continuousTimeAtReceipt,
                    authorizedLifetime: receipt.authorizedLeaseDuration
                )
            )
            current.pendingRegistration = nil
            // A sign-out/token-invalidated flow still needs DELETE; a normal current intent may become active.
            current.revocationRequested = revokeBeforeNextRegistration
            do {
                try stateStore.save(current)
            } catch {
                // The pending record remains durable because the atomic Keychain update failed.
                return .stop
            }
            do {
                try stateStore.clearAuthorityDenial()
            } catch {
                // Registration exists but remains locally non-actionable. A later lifecycle trigger retries a renewal
                // and marker clear because the valid-binding fast path also requires authorityIsDenied == false.
                return .stop
            }
            if revokeBeforeNextRegistration {
                reconcileRequested = true
                return .continueImmediately
            }
            return intentStillCurrent(pending, voipToken: voipToken, bearer: bearer)
                ? .stop
                : .continueImmediately
        } catch is CancellationError {
            return .stop
        } catch let error as DeviceRingRegistrationError {
            guard generation == operationGeneration,
                  conflictMayMutate(pending, voipToken: voipToken, bearer: bearer) else {
                return .stop
            }
            switch error {
            case .registrationDeniedBeforeCommit:
                // This terminal outcome proves the exact operation never committed. Retire only that persisted UUID;
                // if the same intent is still current, the next pass may safely mint a distinct admitted operation.
                return discardPendingIfCurrent(pending) &&
                    intentStillCurrent(pending, voipToken: voipToken, bearer: bearer)
                    ? .continueImmediately
                    : .stop
            case .bindingConflict(let currentFence):
                return updatePending(pending) { old in
                    DeviceRingPendingRegistration(
                        sessionId: old.sessionId,
                        platform: old.platform,
                        tokenDigest: old.tokenDigest,
                        credentialFingerprint: old.credentialFingerprint,
                        ownerVersion: old.ownerVersion,
                        ownerHandle: old.ownerHandle,
                        idempotencyKey: old.idempotencyKey,
                        expectedBindingId: currentFence?.bindingId,
                        expectedBindingRevision: currentFence?.bindingRevision,
                        expectedTokenClaimId: old.expectedTokenClaimId,
                        expectedTokenClaimRevision: old.expectedTokenClaimRevision
                    )
                } ? .continueImmediately : .stop
            case .tokenClaimConflict(let currentFence):
                return updatePending(pending) { old in
                    DeviceRingPendingRegistration(
                        sessionId: old.sessionId,
                        platform: old.platform,
                        tokenDigest: old.tokenDigest,
                        credentialFingerprint: old.credentialFingerprint,
                        ownerVersion: old.ownerVersion,
                        ownerHandle: old.ownerHandle,
                        idempotencyKey: old.idempotencyKey,
                        expectedBindingId: old.expectedBindingId,
                        expectedBindingRevision: old.expectedBindingRevision,
                        expectedTokenClaimId: currentFence?.tokenClaimId,
                        expectedTokenClaimRevision: currentFence?.tokenClaimRevision
                    )
                } ? .continueImmediately : .stop
            case .registrationConflict:
                return .retryAfterBackoff
            case .registrationCommittedButUnauthorized(let receipt),
                 .registrationExpired(let receipt):
                // This is proof that the ambiguous POST committed, but never lease authority. Persist only its exact
                // fences behind the independent deny marker, then compare-delete that recovered binding.
                let shouldDelete = transitionRecoveredPendingToRevocation(
                    pending,
                    receipt: receipt
                )
                revokeSelectedSessionIfCurrent(pending.sessionId)
                if shouldDelete {
                    revokeBeforeNextRegistration = true
                    return .continueImmediately
                }
                return .stop
            case .notAuthorized:
                // A generic 403 is not proof that this POST missed: an original in-flight attempt can still commit
                // after a retry's read. Close local authority and retain the exact pending bytes/idempotency key so the
                // digest-only cleanup endpoint can durably deny or delete that exact operation.
                _ = markPendingForRevocationRecovery(pending)
                revokeSelectedSessionIfCurrent(pending.sessionId)
                revokeBeforeNextRegistration = true
                return .stop
            case .ownerConflict:
                // The gateway recomputed a different authenticated owner. Retain the only operation capability and
                // close local authority; no account may discard or transfer another owner's registry state.
                _ = markPendingForRevocationRecovery(pending)
                revokeSelectedSessionIfCurrent(pending.sessionId)
                revokeBeforeNextRegistration = true
                return .stop
            case .idempotencyConflict, .targetCapacity, .revisionExhausted,
                 .clientUpgradeRequired, .notConfigured, .rejected:
                if revokeBeforeNextRegistration {
                    // During revoke this pending request may have committed despite an earlier lost response. Never
                    // discard the only replay key/fence and then falsely delete just the older binding.
                    return .stop
                }
                discardPendingIfCurrent(pending)
                return .stop
            case .notLoggedIn, .reauthenticationRequired, .supersededAuthentication,
                 .retryable, .malformedResponse, .network:
                // Transport/200-decode ambiguity keeps the same request bytes and idempotency key for the next trigger.
                return .stop
            }
        } catch {
            return .stop
        }
    }

    private func intentStillCurrent(
        _ pending: DeviceRingPendingRegistration,
        voipToken: String,
        bearer: String
    ) -> Bool {
        authenticated &&
        !revokeBeforeNextRegistration &&
        selectedSessionId == pending.sessionId &&
        latestToken == voipToken &&
        bearerProvider() == bearer &&
        pending.tokenDigest == DeviceRingFingerprint.digest(voipToken) &&
        pending.credentialFingerprint == DeviceRingFingerprint.digest(bearer)
    }

    private func conflictMayMutate(
        _ pending: DeviceRingPendingRegistration,
        voipToken: String,
        bearer: String
    ) -> Bool {
        guard authenticated,
              latestToken == voipToken,
              bearerProvider() == bearer,
              pending.tokenDigest == DeviceRingFingerprint.digest(voipToken),
              pending.credentialFingerprint == DeviceRingFingerprint.digest(bearer) else {
            return false
        }
        return revokeBeforeNextRegistration || selectedSessionId == pending.sessionId
    }

    private func revokeSelectedSessionIfCurrent(_ sessionId: String) {
        guard selectedSessionId == sessionId else { return }
        selectedSessionId = nil
        generation &+= 1
        onSessionAuthorizationRevoked?(sessionId)
    }

    private func markPendingForRevocationRecovery(
        _ expected: DeviceRingPendingRegistration
    ) -> Bool {
        do {
            try stateStore.denyAuthority()
        } catch {
            return false
        }
        guard var state = try? stateStore.load(),
              state.pendingRegistration == expected else { return false }
        state.revocationRequested = true
        do {
            try stateStore.save(state)
            return true
        } catch {
            return false
        }
    }

    private func transitionRecoveredPendingToRevocation(
        _ expected: DeviceRingPendingRegistration,
        receipt: DeviceRingRevocationReceipt
    ) -> Bool {
        guard receipt.ownerVersion == expected.ownerVersion,
              receipt.ownerHandle == expected.ownerHandle,
              receipt.sessionId == expected.sessionId,
              receipt.platform == expected.platform else { return false }
        do {
            try stateStore.denyAuthority()
        } catch {
            return false
        }
        guard var state = try? stateStore.load(),
              state.pendingRegistration == expected else { return false }
        state.binding = DeviceRingBindingRecord(
            sessionId: expected.sessionId,
            platform: expected.platform,
            tokenDigest: expected.tokenDigest,
            credentialFingerprint: expected.credentialFingerprint,
            ownerVersion: expected.ownerVersion,
            ownerHandle: expected.ownerHandle,
            bindingId: receipt.bindingId,
            bindingRevision: receipt.bindingRevision,
            tokenClaimId: receipt.tokenClaimId,
            tokenClaimRevision: receipt.tokenClaimRevision,
            expiresAt: receipt.expiresAt,
            leaseAuthority: nil
        )
        state.pendingRegistration = nil
        state.revocationRequested = true
        do {
            try stateStore.save(state)
            return true
        } catch {
            return false
        }
    }

    private func updatePending(
        _ expected: DeviceRingPendingRegistration,
        transform: (DeviceRingPendingRegistration) -> DeviceRingPendingRegistration
    ) -> Bool {
        guard var state = try? stateStore.load(),
              state.pendingRegistration == expected else { return false }
        state.pendingRegistration = transform(expected)
        do {
            try stateStore.save(state)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func discardPendingIfCurrent(_ expected: DeviceRingPendingRegistration) -> Bool {
        guard var state = try? stateStore.load(),
              state.pendingRegistration == expected else { return false }
        state.pendingRegistration = nil
        if state.revocationRequested && state.binding == nil {
            // Keep no invalid marker-only envelope; there is no exact tuple left to delete.
            state.revocationRequested = false
        }
        do {
            try stateStore.save(state)
            return true
        } catch {
            return false
        }
    }

    deinit {
        worker?.cancel()
    }
}
