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

    /// Abandon the draft/confirmation — a cancelled decision must leave NOTHING posted or queued.
    func cancel() {
        pendingIntent = nil
        OutboxStore.clear()
        state = .composing
    }

    /// Retry a PENDING (offline) intent after reconnect — resends the identical confirmed bytes.
    func retryPending() {
        guard case .pending = state, let intent = pendingIntent else { return }
        post(intent.proposal, intent.confirmation)
    }

    private func post(_ proposal: ActionProposal, _ confirmation: GovernedWriteConfirmation) {
        state = .sending
        Task { [weak self] in
            guard let self else { return }
            do {
                // execute() already fails-closed to a structurally-valid .posted (else it throws) — no optimistic sent.
                let receipt = try await self.client.execute(proposal: proposal, confirmation: confirmation)
                self.applyRenderGate(receipt)
            } catch PocketWriteError.network(let detail) {
                // OFFLINE: the POST couldn't reach the gateway → PENDING, retryable. PERSIST the confirmed intent so
                // it survives an app kill (durable outbox); NEVER "sent".
                OutboxStore.save(PersistedWriteIntent(proposal: proposal, confirmation: confirmation))
                self.state = .pending("Offline — your message is queued and will send when you reconnect. (\(detail))")
            } catch PocketWriteError.retryable(let detail) {
                // TRANSIENT gateway response (busy / in-progress / temporarily unavailable) — NOT terminal. Queue +
                // retry exactly like offline; the write may still land, so we must never refuse it.
                OutboxStore.save(PersistedWriteIntent(proposal: proposal, confirmation: confirmation))
                self.state = .pending("The gateway is busy — queued, tap Retry. (\(detail))")
            } catch PocketWriteError.notPosted(let why) {
                // The gateway returned a receipt that is NOT a verified posted (pending/failed) → never sent.
                self.pendingIntent = nil
                OutboxStore.clear()
                self.state = .refused("Not sent — \(why)")
            } catch PocketWriteError.rejected(let why) {
                self.pendingIntent = nil
                OutboxStore.clear()
                self.state = .refused("The gateway refused this write — \(why)")
            } catch {
                self.pendingIntent = nil
                OutboxStore.clear()
                self.state = .refused("Not sent — \(error.localizedDescription)")
            }
        }
    }

    /// The 🔴 RENDER-GATE (item 3): a real .posted receipt is only "sent" if its gateway signature VERIFIES under the
    /// pinned key. Anything else (unsigned / tampered / no CryptoKit) is REFUSED, never rendered as sent.
    private func applyRenderGate(_ receipt: ActionReceipt) {
        // Every path here is TERMINAL (sent or refused) — the confirmed intent is resolved, so drop the durable outbox.
        OutboxStore.clear()
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
