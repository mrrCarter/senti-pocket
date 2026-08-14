// PocketPhoneView — B2 real UI (warden #261831 item 1): renders the reasoning coordinator's ReasoningPhase (kills
// the old static RootView List) + the phone-write flow (compose → EXPLICIT confirm → honest result). All honesty
// decisions live in the view-models; this view only reflects their state.

#if canImport(SwiftUI)
import SwiftUI
import PocketContracts
import PocketReasoning
import PocketUI

struct PocketPhoneView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var reasoning: RealReasoningCoordinator
    @ObservedObject var write: PhoneWriteViewModel
    private let reasoningLifecycle: PocketPhoneReasoningLifecycle
    @State private var draft: String = ""

    init(
        reasoning: RealReasoningCoordinator,
        write: PhoneWriteViewModel,
        connectivityUpdates: ReasoningConnectivityUpdates = ReasoningConnectivityUpdates()
    ) {
        _reasoning = ObservedObject(wrappedValue: reasoning)
        _write = ObservedObject(wrappedValue: write)
        reasoningLifecycle = PocketPhoneReasoningLifecycle(
            reasoning: reasoning,
            makeUpdates: { connectivityUpdates.stream() }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                briefingSection
                writeSection
            }
            .navigationTitle("Senti Pocket")
            .task(id: scenePhase) {
                await reasoningLifecycle.run(isActive: scenePhase == .active)
            }
            .onDisappear { reasoningLifecycle.stop() }
        }
    }

    // MARK: reasoning (the briefing)

    @ViewBuilder private var briefingSection: some View {
        Section("Briefing") {
            switch reasoning.phase {
            case .idle, .briefingLoading:
                HStack(spacing: 8) { ProgressView(); Text("Reasoning over your checkpoint…").foregroundStyle(.secondary) }
            case .briefingReady(let plan, let provenance):
                provenanceLabel(provenance)
                ForEach(plan.segments, id: \.sentiOpaqueIdentity) { seg in
                    Text(seg.text).font(.subheadline)
                }
            case .answerLoading(let question):
                HStack(spacing: 8) { ProgressView(); Text("Answering “\(question)”…").foregroundStyle(.secondary) }
            case .answered(let answer, let provenance):
                provenanceLabel(provenance); answerView(answer)
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote)
            }
        }
    }

    @ViewBuilder private func provenanceLabel(_ p: ReasoningProvenance) -> some View {
        switch p {
        case .liveReasoned:
            Label("Live reasoned", systemImage: "bolt.fill").font(.caption).foregroundStyle(.green)
        case .cachedSample:
            Label("Cached sample — not a live reasoned brief", systemImage: "clock.arrow.circlepath")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func answerView(_ answer: ReasonedAnswer) -> some View {
        switch answer {
        case .answered(let qa):
            Text(qa.text).font(.subheadline)
            if !qa.evidenceIds.isEmpty {
                Text("grounded in \(qa.evidenceIds.count) evidence ref\(qa.evidenceIds.count == 1 ? "" : "s")")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        case .clarify(let prompt, let options):
            Text(prompt).font(.subheadline)
            ForEach(options, id: \.self) { Text("• \($0)").font(.caption) }
        case .unavailable(let topics):
            Text("No grounded answer — here's the nearest cached context:").font(.caption).foregroundStyle(.secondary)
            ForEach(topics) { Text("• \($0.label)").font(.caption) }
        }
    }

    // MARK: write (the milestone — post as you)

    @ViewBuilder private var writeSection: some View {
        Section("Reply as you") {
            switch write.state {
            case .composing:
                TextField("Dictate a message…", text: $draft, axis: .vertical).lineLimit(1...4)
                Button("Review & send") { write.draft(draft) }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .confirming(let proposal):
                confirmView(proposal)
            case .sending:
                HStack(spacing: 8) { ProgressView(); Text("Posting as you…").foregroundStyle(.secondary) }
            case .sent(let receipt):
                Label("Sent — appeared in the room as you", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Text("verified receipt · signed by \(receipt.signingKeyId)")
                    .font(.caption2).foregroundStyle(.secondary)
                Button("Write another") { write.cancel(); draft = "" }
            case .pending(let message):
                Label(message, systemImage: "wifi.slash").font(.footnote).foregroundStyle(.orange)
                Button("Retry now") { write.retryPending() }
            case .blockedByPendingSession(let targetSessionId):
                Label(
                    "A confirmed message is queued for session \(targetSessionId). Return to that session to retry it.",
                    systemImage: "lock.shield"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            case .refused(let message):
                Label(message, systemImage: "xmark.seal.fill").font(.footnote).foregroundStyle(.red)
                Button("Back") { write.cancel() }
            }
        }
    }

    @ViewBuilder private func confirmView(_ proposal: ActionProposal) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Post this into the session AS YOU:").font(.caption).foregroundStyle(.secondary)
            Text(proposal.renderedPreview)
                .font(.body)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            Text("session \(proposal.targetSessionId)").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Cancel", role: .cancel) { write.cancel() }
                Spacer()
                // The EXPLICIT human tap — the ONLY path that posts. Never auto-confirmed (warden finding #2).
                Button("Send as me") { write.confirm() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 4)
    }
}

private extension BriefingSegment {
    var sentiOpaqueIdentity: OpaqueUTF8Identity { OpaqueUTF8Identity(id) }
}

/// Owns the reasoning observation at the SwiftUI lifecycle boundary while keeping active/inactive/disappearance
/// behavior directly testable without fabricating `ScenePhase` environment updates. Parent task cancellation is
/// forwarded to the exact observation task; inactive and disappearing views synchronously fence all late work.
@MainActor
struct PocketPhoneReasoningLifecycle {
    private let reasoning: RealReasoningCoordinator
    private let makeUpdates: @Sendable () -> AsyncStream<PocketConnectivity>

    init(
        reasoning: RealReasoningCoordinator,
        makeUpdates: @escaping @Sendable () -> AsyncStream<PocketConnectivity>
    ) {
        self.reasoning = reasoning
        self.makeUpdates = makeUpdates
    }

    func run(isActive: Bool) async {
        guard isActive else {
            reasoning.reset()
            return
        }
        let observation = reasoning.observeConnectivity(makeUpdates())
        await withTaskCancellationHandler {
            await observation.value
        } onCancel: {
            observation.cancel()
        }
    }

    func stop() {
        reasoning.reset()
    }
}
#endif
