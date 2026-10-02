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
    case reconciling(String)       // AUTHORIZED write whose network attempt was INTERRUPTED (cancelled) before a
                                   // terminal gateway result — the confirmed intent is DURABLY retained + reconcilable;
                                   // NOT "sent", NOT a durable offline .pending, and NOT erasable by a later cancel.
    case unavailable(String)       // a previously-authorized intent restored while NO gateway is configured — RETAINED
                                   // (durable + in-memory) but it will NOT send until a configured launch. NOT
                                   // connectivity-pending (no false "will send when you reconnect"), NO reconnect-retry,
                                   // and hangup/cancel PRESERVE it (never orphan/delete/wire it). (Pulse round-9.)
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
        // Restore a confirmed-but-unsent write from a previous session (durable outbox) so an offline write survives an
        // app kill. Retain BOTH in-memory + durable ownership; NEVER auto-fired here, NEVER shown as sent. Present it
        // HONESTLY by endpoint readiness (Pulse round-9):
        //  • CONFIGURED client → ordinary explicit-retry .pending (connectivity — retry resends on reconnect).
        //  • UNCONFIGURED (nil) client → .unavailable: retained, but a nil endpoint can't be repaired by a reconnect, so
        //    it will NOT send until a configured launch. NO false "will send when you reconnect", NO reconnect-retry;
        //    hangup/cancel PRESERVE it (never orphan/delete/wire it), and a later configured launch restores it as .pending.
        if let persisted = OutboxStore.load() {
            pendingIntent = (persisted.proposal, persisted.confirmation)
            if client.isConfigured {
                state = .pending("A message you confirmed earlier is queued — it will send when you reconnect.")
            } else {
                state = .unavailable("A message you confirmed earlier is held. No gateway is configured, so it will not send until the app is launched with a valid gateway.")
            }
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
    /// that owns the single global slot. NEVER erases a `.reconciling` attempt (an authorized write whose outcome is
    /// unknown may have landed server-side — it cannot be retracted).
    func cancel() {
        if case .reconciling = state { return }   // an interrupted authorized attempt is retained, never erased
        if case .unavailable = state { return }   // Pulse round-9: never orphan/delete a retained intent held for a configured launch
        if let id = currentProposalId { OutboxStore.clear(proposalId: id) }
        pendingIntent = nil
        state = .composing
    }

    /// Call-HANGUP teardown seam (spec C): cancel ONLY a PRE-SUBMIT draft (composing/confirming — nothing was
    /// authorized, so this yields zero POST/queue). Once the write is authorized (.sending), reconciling, or terminal
    /// (.pending/.sent/.refused) this is a NO-OP: an accepted server write cannot be retracted and a durable
    /// pending/reconciling attempt stays retained — a hangup stops call audio but MUST NOT cancel/erase it.
    func cancelIfUnsubmitted() {
        switch state {
        case .composing, .confirming: cancel()
        case .sending, .pending, .sent, .refused, .reconciling, .unavailable: break   // authorized/terminal/held — retain
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
        // NIL-GATEWAY HONESTY (Pulse round-8) — the SYNCHRONOUS ownership boundary, guarded BEFORE any durable save.
        // If no gateway is configured, REFUSE now: create NO durable intent (no OutboxStore.save), read NO token, make
        // NO request, and leave NO transient persisted state. A nil endpoint can never be repaired by a reconnect, so a
        // false ".pending"/"offline queued" would be dishonest and would leak a write that might post after a later
        // config change. (The write path composes an unavailable/non-writing client when the endpoint is nil.)
        guard client.isConfigured else {
            pendingIntent = nil
            state = .refused("No gateway is configured — the message was not sent.")
            return
        }
        // DURABLE OWNERSHIP BEFORE ANY NETWORK (Pulse): persist the confirmed intent and only send if we actually
        // OWN the durable slot. A crash / app-kill during the `.sending` window then can't silently drop a
        // Carter-confirmed write — the durable-outbox guarantee covers the in-flight window (the "in-memory only →
        // lost on kill" gap). The SAME proposal id is persisted + restored + resent verbatim, so the gateway's
        // (principal, proposal.id) crash-recovery dedups a restart-retry — never a double-post. If save() returns
        // false — a DIFFERENT confirmed write owns the slot, OR the persist failed — we CANNOT crash-safely record
        // this write, so we do NOT POST (honor save()==false; never send something we can't recover). A foreign
        // owner is left intact.
        guard OutboxStore.save(PersistedWriteIntent(proposal: proposal, confirmation: confirmation)) else {
            pendingIntent = nil
            state = .refused("Couldn't secure the outbox for this write — not sent. Another confirmed write may still be pending.")
            return
        }
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
                // Spec C / Pulse: the POST was cancelled/interrupted BEFORE a terminal gateway result. NOT an
                // offline/connectivity condition, so it must NOT surface as a durable .pending. And since the request
                // may have LANDED server-side, the confirmed intent is RETAINED for reconciliation. Enter the explicit
                // RECONCILING phase: the durable outbox stays (reconciled on next launch); cancel()/cancelIfUnsubmitted()
                // must NOT erase it; the adapter reports it as retained (never a false "not posted"). Normal teardown
                // does NOT cancel this (detached, retained) Task — this is the app-suspend guard.
                self.state = .reconciling("Interrupted before the gateway confirmed — your confirmed message is retained and will reconcile.")
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
