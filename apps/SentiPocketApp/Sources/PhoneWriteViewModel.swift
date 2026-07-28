// PhoneWriteViewModel — B2, the phone-write integration state machine (warden #261831 gate checklist items 2-4).
// This is the milestone: Carter dictates → EXPLICIT human confirm → the write posts as human-mrrcarter → the app
// renders "sent — appeared as you" ONLY behind a verified signature. Every honesty gate is enforced HERE (warden
// source-verifies these), the SwiftUI just renders `state`.
//
// HONESTY INVARIANTS (never violate):
//  - NEVER auto-confirm: a proposal only posts from `confirm()`, reachable solely by an explicit human tap (item 2).
//  - RENDER-GATE (item 3): show `.sent` ONLY if the receipt's gateway signature verifies under the PINNED key.
//    .invalid/.unsigned → `.refused`, never sent (tamper-safe).
//  - OFFLINE HONESTY (item 4): a network failure → `.pending` (retryable, intent retained), NEVER "sent"/"failed".
//    A non-.posted receipt (pending/failed) → `.refused`. No optimistic "sent" before the verified .posted.

import Foundation
import PocketContracts

enum PhoneWriteState: Equatable {
    case composing                 // drafting a message to dictate
    case confirming(ActionProposal) // CONFIRM UI: rendered preview + target session, awaiting the explicit human tap
    case sending
    case sent(ActionReceipt)       // render-gate PASSED: structurally-valid .posted AND signature .verified under the pin
    case pending(String)           // offline: PENDING_CONNECTIVITY — retryable, intent retained; never "sent"
    case refused(String)           // rejected / non-posted / signature-not-verified — NEVER "sent"
}

@MainActor
final class PhoneWriteViewModel: ObservableObject {
    @Published private(set) var state: PhoneWriteState = .composing

    private let sessionId: String
    private let client: PocketWriteClient

    /// Item 3: the gateway receipt-signing PUBLIC key, HARD-CODED (forge #261850: bound to the fixed signing key,
    /// stable across restarts). We verify the receipt under THIS pin — we do NOT fetch /demo-pubkey and trust it.
    private let gatewayPublicKeyPin = "dTyRfSKF07JPaC_0CgCxhL0t6a3laUV0vY2VxUgeKXo"

    /// The confirmed intent, retained across an offline failure so `retryPending()` can resend the SAME bytes (the
    /// hash/confirmation are already bound — a retry re-posts identically; the gateway is idempotent by proposal id).
    private var pendingIntent: (proposal: ActionProposal, confirmation: GovernedWriteConfirmation)?

    init(sessionId: String, client: PocketWriteClient) {
        self.sessionId = sessionId
        self.client = client
        // Restore a confirmed-but-unsent write from a previous session (durable outbox) so an offline write survives
        // an app kill. It's already human-confirmed — surfaced as PENDING + retryable; NEVER auto-fired here (retry
        // is an explicit user tap or an app-driven reconnect), NEVER shown as sent.
        if let persisted = OutboxStore.load() {
            pendingIntent = (persisted.proposal, persisted.confirmation)
            state = .pending("A message you confirmed earlier is queued — it will send when you reconnect.")
        }
    }

    /// Compose → show the CONFIRM UI. Builds the humanMessage proposal (seq:0) but does NOT post — the human must tap.
    func draft(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state = .confirming(PocketWriteClient.makeHumanMessageProposal(sessionId: sessionId, message: trimmed))
    }

    /// EXPLICIT human confirmation (item 2). MUST be called only from a deliberate human tap on the confirm control —
    /// never from a timer, a default, or an auto-advance. Binds the EXACT hash the human saw.
    func confirm() {
        guard case .confirming(let proposal) = state else { return }
        let confirmation = GovernedWriteConfirmation(
            proposalId: proposal.id,
            confirmedProposalHash: proposal.proposalHash,   // == the hash of the content shown in the confirm UI
            confirmedAt: Date()
        )
        pendingIntent = (proposal, confirmation)
        post(proposal, confirmation)
    }

    /// Abandon the draft/confirmation — a cancelled decision must leave NOTHING posted or queued. Clears the durable
    /// outbox STRICTLY by the current proposal's id (spec C) so it can never wipe a DIFFERENT confirmed pending write
    /// that owns the single global slot.
    func cancel() {
        if let id = currentProposalId { OutboxStore.clear(proposalId: id) }
        pendingIntent = nil
        state = .composing
    }

    /// Call-HANGUP teardown seam (spec C): cancel ONLY a PRE-SUBMIT draft (composing/confirming — nothing was
    /// authorized, so this yields zero POST/queue). Once the write is authorized (.sending) or terminal
    /// (.pending/.sent/.refused) this is a NO-OP: an accepted server write cannot be retracted and a durable pending
    /// stays reconcilable, so a later hangup stops call audio but MUST NOT cancel/erase that authorized attempt.
    func cancelIfUnsubmitted() {
        switch state {
        case .composing, .confirming: cancel()
        case .sending, .pending, .sent, .refused: break   // authorized/terminal — retain the reconcilable proposal
        }
    }

    /// The proposal id currently in play (the armed draft, else a persisted pending intent) — the key we clear the
    /// single-slot outbox by, so a clear never wipes a different proposal's entry.
    private var currentProposalId: String? {
        if case .confirming(let p) = state { return p.id }
        return pendingIntent?.proposal.id
    }

    /// Retry a PENDING (offline) intent after reconnect — resends the identical confirmed bytes.
    func retryPending() {
        guard case .pending = state, let intent = pendingIntent else { return }
        post(intent.proposal, intent.confirmation)
    }

    private func post(_ proposal: ActionProposal, _ confirmation: GovernedWriteConfirmation) {
        // Persist the confirmed intent BEFORE the send so a crash / app-kill during the `.sending` window can't
        // silently drop a Carter-confirmed governed write — the durable-outbox guarantee must cover the in-flight
        // window, not only the offline catches (the exact "in-memory only → lost on kill" gap OutboxStore exists to
        // close). The SAME proposal id is persisted + restored + resent verbatim, so the gateway's (principal,
        // proposal.id) crash-recovery dedups a restart-retry — never a double-post (prior-posted → same receipt;
        // in-flight/unknown → 409 reconcile, never a blind re-post). Every terminal path below (applyRenderGate /
        // refused / cancel) clears the outbox, so a success/refusal leaves nothing queued.
        OutboxStore.save(PersistedWriteIntent(proposal: proposal, confirmation: confirmation))
        state = .sending
        Task { [weak self] in
            guard let self else { return }
            do {
                // execute() already fails-closed to a structurally-valid .posted (else it throws) — no optimistic sent.
                let receipt = try await self.client.execute(proposal: proposal, confirmation: confirmation)
                self.applyRenderGate(receipt)
            } catch PocketWriteError.network(let detail) {
                // OFFLINE: the POST couldn't reach the gateway → PENDING, retryable. The confirmed intent was already
                // persisted at the top of post() (durable outbox), so it survives an app kill; NEVER "sent".
                self.state = .pending("Offline — your message is queued and will send when you reconnect. (\(detail))")
            } catch PocketWriteError.retryable(let detail) {
                // TRANSIENT gateway response (busy / in-progress / temporarily unavailable) — NOT terminal. Queue +
                // retry like offline; the write may still land, so never refuse it (intent already persisted, top of post()).
                self.state = .pending("The gateway is busy — queued, tap Retry. (\(detail))")
            } catch PocketWriteError.cancelled {
                // Spec C: the POST was cancelled (call torn down / task cancelled) BEFORE a terminal gateway result.
                // This is NOT an offline/connectivity condition, so it must NOT surface as a durable .pending (which
                // would falsely claim the write is queued to send). The confirmed intent stays in the durable outbox
                // (RETAINED — reconcilable on next launch, where init() restores it as pending): we neither clear it
                // nor claim it sent/queued here. Normal teardown does NOT cancel this (unstructured, retained) Task —
                // this is the app-suspend guard. Live state returns to neutral; the durable outbox is the source of truth.
                self.state = .composing
            } catch PocketWriteError.notPosted(let why) {
                // The gateway returned a receipt that is NOT a verified posted (pending/failed) → never sent.
                self.pendingIntent = nil
                OutboxStore.clear(proposalId: proposal.id)
                self.state = .refused("Not sent — \(why)")
            } catch PocketWriteError.rejected(let why) {
                self.pendingIntent = nil
                OutboxStore.clear(proposalId: proposal.id)
                self.state = .refused("The gateway refused this write — \(why)")
            } catch {
                self.pendingIntent = nil
                OutboxStore.clear(proposalId: proposal.id)
                self.state = .refused("Not sent — \(error.localizedDescription)")
            }
        }
    }

    /// The 🔴 RENDER-GATE (item 3): a real .posted receipt is only "sent" if its gateway signature VERIFIES under the
    /// pinned key. Anything else (unsigned / tampered / no CryptoKit) is REFUSED, never rendered as sent.
    private func applyRenderGate(_ receipt: ActionReceipt) {
        // Every path here is TERMINAL (sent or refused) — the confirmed intent is resolved, so drop the durable outbox.
        // Clear STRICTLY by the receipt's proposal id (spec C): a terminal for OUR write never wipes a foreign owner.
        OutboxStore.clear(proposalId: receipt.proposalId)
        #if canImport(CryptoKit)
        switch receipt.signatureState(gatewayPublicKeyBase64url: gatewayPublicKeyPin) {
        case .verified:
            pendingIntent = nil
            state = .sent(receipt)
        case .invalid:
            pendingIntent = nil
            state = .refused("Not sent — the receipt signature did not verify (possible tampering).")
        case .unsigned:
            pendingIntent = nil
            state = .refused("Not sent — the receipt was not signed by the gateway.")
        }
        #else
        pendingIntent = nil
        state = .refused("Not sent — the receipt signature cannot be verified on this platform.")
        #endif
    }
}
