// PhoneWriteViewModel — B2, the phone-write integration state machine (warden #261831 gate checklist items 2-4).
// This is the milestone: Carter dictates → EXPLICIT human confirm → the write posts as human-mrrcarter → the app
// renders "sent — appeared as you" ONLY behind a verified receipt. Every honesty gate is enforced HERE (warden
// source-verifies these), the SwiftUI just renders `state`.
//
// HONESTY INVARIANTS (never violate):
//  - NEVER auto-confirm: a proposal only posts from `confirm()`, reachable solely by an explicit human tap (item 2).
//  - RENDER-GATE (item 3): show `.sent` ONLY when `VerifiedActionReceipt` binds the receipt to the exact proposal,
//    confirmation, result semantics, signing-key id, and gateway signature in the immutable registry.
//  - OFFLINE HONESTY (item 4): a network failure → `.pending` (retryable, intent retained), NEVER "sent"/"failed".
//    An unauthenticated/ambiguous receipt remains `.pending` with its durable intent. No optimistic "sent".

import Foundation
import PocketContracts

enum PhoneWriteState: Equatable {
    case composing                 // drafting a message to dictate
    case confirming(ActionProposal) // CONFIRM UI: rendered preview + target session, awaiting the explicit human tap
    case sending
    case sent(VerifiedActionReceipt) // complete proposal/confirmation/result/key/signature admission passed
    case pending(String)           // offline: PENDING_CONNECTIVITY — retryable, intent retained; never "sent"
    case blockedByPendingSession(String) // another session owns the one durable outbox slot; never retry/clear it here
    case refused(String)           // definitive pre-send/auth/terminal rejection — NEVER "sent"
}

@MainActor
final class PhoneWriteViewModel: ObservableObject {
    @Published private(set) var state: PhoneWriteState = .composing

    private let sessionId: String
    private let client: PocketWriteClient
    private let onReauthenticationRequired: @MainActor (String?) -> Void
    private let isWriteAuthorized: @MainActor () -> Bool

    /// The confirmed intent, retained across an offline failure so `retryPending()` can resend the SAME bytes (the
    /// hash/confirmation are already bound — a retry re-posts identically; the gateway is idempotent by proposal id).
    private var pendingIntent: (proposal: ActionProposal, confirmation: GovernedWriteConfirmation)?
    private var writeRevision: UInt64 = 0

    init(
        sessionId: String,
        client: PocketWriteClient,
        onReauthenticationRequired: @escaping @MainActor (String?) -> Void = { _ in },
        isWriteAuthorized: @escaping @MainActor () -> Bool = { true }
    ) {
        self.sessionId = sessionId
        self.client = client
        self.onReauthenticationRequired = onReauthenticationRequired
        self.isWriteAuthorized = isWriteAuthorized
        // Restore a confirmed-but-unsent write from a previous session (durable outbox) so an offline write survives
        // an app kill. It's already human-confirmed — surfaced as PENDING + retryable; NEVER auto-fired here (retry
        // is an explicit user tap or an app-driven reconnect), NEVER shown as sent.
        if let persisted = OutboxStore.load() {
            switch persisted.binding(to: sessionId) {
            case .matching:
                pendingIntent = (persisted.proposal, persisted.confirmation)
                state = .pending(
                    "A confirmed message for session \(sessionId) is queued — retry when you are connected."
                )
            case .foreignSession(let targetSessionId):
                // The outbox is intentionally global/single-intent. A different selected session must neither retry
                // nor overwrite nor clear that intent; the user must return to its explicitly named target.
                state = .blockedByPendingSession(targetSessionId)
            case .invalid:
                OutboxStore.clear(matching: persisted)
                state = .refused("Not sent — the saved write did not pass its confirmation integrity checks.")
            }
        }
    }

    /// Compose → show the CONFIRM UI. Builds the humanMessage proposal (seq:0) but does NOT post — the human must tap.
    func draft(_ message: String) {
        guard case .composing = state, isWriteAuthorized() else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state = .confirming(PocketWriteClient.makeHumanMessageProposal(sessionId: sessionId, message: trimmed))
    }

    /// EXPLICIT human confirmation (item 2). MUST be called only from a deliberate human tap on the confirm control —
    /// never from a timer, a default, or an auto-advance. Binds the EXACT hash the human saw.
    func confirm() {
        guard case .confirming(let proposal) = state else { return }
        guard isWriteAuthorized() else {
            state = .refused("Not sent — this session is no longer selected or authorized.")
            return
        }
        let confirmation = GovernedWriteConfirmation(
            proposalId: proposal.id,
            confirmedProposalHash: proposal.proposalHash,   // == the hash of the content shown in the confirm UI
            confirmedAt: Date()
        )
        pendingIntent = (proposal, confirmation)
        post(proposal, confirmation)
    }

    /// Abandon the draft/confirmation — a cancelled decision must leave NOTHING posted or queued.
    func cancel() {
        // A view composed for session B has no authority to discard session A's persisted confirmed intent.
        if case .blockedByPendingSession = state { return }
        writeRevision &+= 1
        if let pendingIntent {
            OutboxStore.clear(matching: PersistedWriteIntent(
                proposal: pendingIntent.proposal,
                confirmation: pendingIntent.confirmation
            ))
        }
        pendingIntent = nil
        state = .composing
    }

    /// Retry a PENDING (offline) intent after reconnect — resends the identical confirmed bytes.
    func retryPending() {
        guard case .pending = state, let intent = pendingIntent else { return }
        post(intent.proposal, intent.confirmation)
    }

    private func post(_ proposal: ActionProposal, _ confirmation: GovernedWriteConfirmation) {
        let intent = PersistedWriteIntent(proposal: proposal, confirmation: confirmation)
        guard intent.binding(to: sessionId) == .matching else {
            pendingIntent = nil
            state = .refused("Not sent — the confirmed write is not bound to this selected session.")
            return
        }
        guard isWriteAuthorized() else {
            state = .pending(
                "Session \(sessionId): selection changed before send. Return to this session to retry."
            )
            return
        }
        // Persist the confirmed intent BEFORE the send so a crash / app-kill during the `.sending` window can't
        // silently drop a Carter-confirmed governed write — the durable-outbox guarantee must cover the in-flight
        // window, not only the offline catches (the exact "in-memory only → lost on kill" gap OutboxStore exists to
        // close). The SAME proposal id is persisted + restored + resent verbatim, so the gateway's (principal,
        // proposal.id) crash-recovery dedups a restart-retry — never a double-post (prior-posted → same receipt;
        // in-flight/unknown → 409 reconcile, never a blind re-post). Only verified success, definitive refusal, or
        // explicit cancel clears; an unauthenticated/ambiguous receipt retains the outbox for reconciliation.
        switch OutboxStore.claim(intent) {
        case .claimed:
            break
        case .occupied(let targetSessionId):
            pendingIntent = nil
            state = .blockedByPendingSession(targetSessionId)
            return
        case .storageUnavailable:
            pendingIntent = nil
            state = .refused("Not sent — the confirmed message could not be secured in the device outbox.")
            return
        }
        writeRevision &+= 1
        let operationRevision = writeRevision
        state = .sending
        Task { [weak self] in
            guard let self, self.writeRevision == operationRevision else { return }
            // `confirm()` and this unstructured Task are separated by an executor turn. Recheck the injected
            // selected-session/auth gate here so a revocation in that gap cannot start the HTTP write.
            guard self.isWriteAuthorized() else {
                self.state = .pending(
                    "Session \(self.sessionId): selection changed before send. Return to this session to retry."
                )
                return
            }
            do {
                let verifiedReceipt = try await self.client.execute(
                    proposal: proposal,
                    confirmation: confirmation
                )
                guard self.writeRevision == operationRevision else { return }
                guard self.isWriteAuthorized() else {
                    self.state = .pending(
                        "Session \(self.sessionId): selection changed during send. Retained for reconciliation."
                    )
                    return
                }
                self.applyVerifiedReceipt(verifiedReceipt, resolving: intent)
            } catch {
                guard self.writeRevision == operationRevision else { return }
                guard let writeError = error as? PocketWriteError else {
                    self.state = .pending(
                        "Session \(self.sessionId): the write outcome is unknown — retained for reconciliation. "
                        + "(\(error.localizedDescription))"
                    )
                    return
                }
                switch writeError {
                case .network(let detail):
                // OFFLINE: the POST couldn't reach the gateway → PENDING, retryable. The confirmed intent was already
                // persisted at the top of post() (durable outbox), so it survives an app kill; NEVER "sent".
                self.state = .pending(
                    "Session \(self.sessionId): offline — your message is queued. (\(detail))"
                )
                case .retryable(let detail):
                // TRANSIENT gateway response (busy / in-progress / temporarily unavailable) — NOT terminal. Queue +
                // retry like offline; the write may still land, so never refuse it (intent already persisted, top of post()).
                self.state = .pending(
                    "Session \(self.sessionId): the gateway is busy — queued, tap Retry. (\(detail))"
                )
                case .notLoggedIn:
                // Confirmation authority is tied to the authenticated principal. Once that principal is gone, never
                // carry a retryable intent across a possible account switch; require a fresh review after sign-in.
                self.pendingIntent = nil
                OutboxStore.clear(matching: intent)
                self.state = .refused("Not sent — sign in again, then review this message again.")
                self.onReauthenticationRequired(nil)
                case .reauthenticationRequired(let requestToken):
                self.pendingIntent = nil
                OutboxStore.clear(matching: intent)
                self.state = .refused("Not sent — authorization expired. Sign in and review this message again.")
                self.onReauthenticationRequired(requestToken)
                case .supersededAuthentication:
                self.pendingIntent = nil
                OutboxStore.clear(matching: intent)
                self.state = .refused("Not sent — this response belonged to an earlier sign-in. Review the message again.")
                case .rejected(let why):
                self.pendingIntent = nil
                OutboxStore.clear(matching: intent)
                self.state = .refused("The gateway refused this write — \(why)")
                case .notConfigured:
                self.pendingIntent = nil
                OutboxStore.clear(matching: intent)
                self.state = .refused("Not sent — Senti's secure gateway is not configured for this build.")
                case .malformedResponse:
                    self.state = .pending(
                        "Session \(self.sessionId): the gateway response could not be authenticated — retained for reconciliation."
                    )
                case .unverifiableReceipt:
                    self.state = .pending(
                        "Session \(self.sessionId): the receipt could not be authenticated — retained for reconciliation."
                    )
                }
            }
        }
    }

    private func applyVerifiedReceipt(
        _ verified: VerifiedActionReceipt,
        resolving intent: PersistedWriteIntent
    ) {
        // Verification completed first. The compare-and-swap clear cannot erase a newer principal/session intent.
        OutboxStore.clear(matching: intent)
        pendingIntent = nil
        state = .sent(verified)
    }
}
