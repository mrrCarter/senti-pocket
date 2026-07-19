#if canImport(SwiftUI)
import SwiftUI
import PocketContracts

public struct ConversationView: View {
    private let state: ConversationState
    private let connectivity: PocketConnectivity
    private let send: (PocketUIIntent) -> Void
    @AccessibilityFocusState private var voiceStatusFocused: Bool

    public init(
        state: ConversationState,
        connectivity: PocketConnectivity,
        send: @escaping (PocketUIIntent) -> Void
    ) {
        self.state = state
        self.connectivity = connectivity
        self.send = send
    }

    public var body: some View {
        Group {
            if state.integrity.allowsBriefing {
                conversationContent
            } else {
                integrityBlockedContent
            }
        }
        .navigationTitle("Briefing")
        .accessibilityIdentifier(PocketAccessibilityID.conversationScreen)
        .pocketCanvas()
        .onChange(of: state.voiceState.accessibilityPhase) { _ in
            voiceStatusFocused = true
        }
    }

    private var conversationContent: some View {
        let context = CheckpointContext(bundle: state.bundle)
        let evidenceIndex = EvidenceIndex(evidence: state.bundle.evidence)

        return VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ConnectivityBanner(connectivity: connectivity)
                    conversationHeader(context: context)
                    Text("Grounded briefing")
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)

                    ForEach(state.bundle.summary.perAgent, id: \.agentId) { agent in
                        Section {
                            ForEach(agent.claims) { claim in
                                GroundedClaimRow(
                                    claim: claim,
                                    evidenceIndex: evidenceIndex,
                                    onOpenEvidence: openEvidence
                                )
                            }
                        } header: {
                            Text(verbatim: agent.agentId)
                                .font(.headline)
                                .padding(.top, 6)
                        }

                        Divider()
                            .overlay(PocketPalette.separator)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Conversation")
                            .font(.title2.weight(.bold))
                            .accessibilityAddTraits(.isHeader)

                        ForEach(displayEntries) { entry in
                            ConversationEntryView(
                                entry: entry,
                                evidenceIndex: evidenceIndex,
                                onOpenEvidence: openEvidence
                            )
                        }
                    }
                    .accessibilityIdentifier(PocketAccessibilityID.conversationTranscript)
                }
                .padding(18)
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
            }

            Divider().overlay(PocketPalette.separator)
            controlDock(context: context)
        }
    }

    private var integrityBlockedContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(PocketPalette.danger)
                    .accessibilityHidden(true)
                Text("Conversation blocked")
                    .font(.title2.weight(.bold))
                Text("Senti will not display, narrate, or answer from checkpoint content until integrity verification succeeds.")
                    .font(.body)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let reason = state.integrity.failureReason {
                    Text(verbatim: reason)
                        .font(.caption)
                        .foregroundStyle(PocketPalette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("End of integrity details")
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .accessibilityIdentifier(PocketAccessibilityID.conversationIntegrityBlockedEnd)
            }
            .padding(28)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
        }
        .accessibilityIdentifier(PocketAccessibilityID.conversationIntegrityBlocked)
    }

    private var displayEntries: [ConversationEntry] {
        if state.transcript.isEmpty {
            return state.briefingPlan.segments.map(ConversationEntry.briefing)
        }
        return state.transcript
    }

    private func conversationHeader(context: CheckpointContext) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: voiceIcon)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(voiceColor)
                    .frame(width: 38, height: 38)
                    .background(voiceColor.opacity(0.13), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(voiceTitle)
                        .font(.headline)
                    Text(voiceDetail)
                        .font(.caption)
                        .foregroundStyle(PocketPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
            }

            if case .speaking = state.voiceState {
                Button {
                    send(.interrupt(context))
                } label: {
                    Label("Interrupt Senti", systemImage: "hand.raised.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(PocketPalette.danger)
                .accessibilityIdentifier(PocketAccessibilityID.interrupt)
                .accessibilityHint("Immediately pauses narration so you can ask a question")
            }
        }
        .padding(16)
        .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(PocketPalette.separator.opacity(0.72), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityFocused($voiceStatusFocused)
    }

    private func openEvidence(_ evidence: EvidenceRef) {
        guard let selection = state.evidenceSelection(for: evidence) else { return }
        send(.openEvidence(selection))
    }

    private func controlDock(context: CheckpointContext) -> some View {
        VStack(spacing: 12) {
            PushToTalkControl(
                isActive: state.isPushToTalkActive,
                onBegin: { send(.pushToTalkBegan(context)) },
                onEnd: { send(.pushToTalkEnded(context)) }
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    conversationControlButtons(context: context)
                }
                VStack(spacing: 10) {
                    conversationControlButtons(context: context)
                }
            }
        }
        .padding(14)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func conversationControlButtons(context: CheckpointContext) -> some View {
        controlButton("Stop", systemImage: "stop.fill", id: PocketAccessibilityID.stop) {
            send(.stopNarration(context))
        }
        controlButton("Replay", systemImage: "arrow.counterclockwise", id: PocketAccessibilityID.replay) {
            send(.replayBriefing(context))
        }
        controlButton("End", systemImage: "phone.down.fill", id: PocketAccessibilityID.end) {
            send(.endConversation(context))
        }
    }

    private func controlButton(
        _ title: String,
        systemImage: String,
        id: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(id)
    }

    private var voiceTitle: String {
        switch state.voiceState {
        case .idle: return "Ready"
        case .speaking: return "Senti is speaking"
        case .interrupted: return "Narration interrupted"
        case .listening: return "Listening"
        case .thinking: return "Answering from cached evidence"
        case .error: return "Voice unavailable"
        }
    }

    private var voiceDetail: String {
        switch state.voiceState {
        case .idle: return "Hold the microphone to ask about this checkpoint."
        case .speaking: return "Tap Interrupt or begin speaking to pause immediately."
        case .interrupted: return "Senti stopped. Hold the microphone when you are ready."
        case .listening: return "Release when you finish your question."
        case .thinking: return "Only the cached checkpoint and evidence are being searched."
        case .error(let message): return message
        }
    }

    private var voiceIcon: String {
        switch state.voiceState {
        case .idle: return "waveform"
        case .speaking: return "speaker.wave.2.fill"
        case .interrupted: return "pause.circle.fill"
        case .listening: return "mic.fill"
        case .thinking: return "brain.head.profile"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var voiceColor: Color {
        switch state.voiceState {
        case .idle, .speaking: return PocketPalette.accent
        case .interrupted, .listening, .thinking: return PocketPalette.listening
        case .error: return PocketPalette.danger
        }
    }
}

private struct ConversationEntryView: View {
    let entry: ConversationEntry
    let evidenceIndex: EvidenceIndex
    let onOpenEvidence: (EvidenceRef) -> Void

    var body: some View {
        switch entry {
        case .briefing(let segment):
            VStack(alignment: .leading, spacing: 10) {
                Label("Senti", systemImage: "waveform.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PocketPalette.accent)
                Text(verbatim: segment.text)
                    .fixedSize(horizontal: false, vertical: true)
                EvidenceLinksView(
                    ids: segment.evidenceIds,
                    evidenceIndex: evidenceIndex,
                    emptyLabel: "No supporting evidence",
                    onOpen: onOpenEvidence
                )
            }
            .pocketCard()

        case .questionAnswer(let answer):
            VStack(spacing: 10) {
                VStack(alignment: .trailing, spacing: 5) {
                    Text("You")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PocketPalette.listening)
                    Text(verbatim: answer.question)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(12)
                .background(PocketPalette.listening.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("Senti", systemImage: "waveform.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PocketPalette.accent)
                        Spacer()
                        if answer.answeredOffline {
                            Label("Answered offline", systemImage: "iphone")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(PocketPalette.warning)
                        }
                    }
                    Text(verbatim: answer.answer)
                        .fixedSize(horizontal: false, vertical: true)
                    EvidenceLinksView(
                        ids: answer.citations,
                        evidenceIndex: evidenceIndex,
                        emptyLabel: "No supporting evidence",
                        onOpen: onOpenEvidence
                    )
                }
                .pocketCard()
            }

        case .notice(let notice):
            Label(notice.text, systemImage: "info.circle.fill")
                .font(.subheadline)
                .foregroundStyle(PocketPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(PocketPalette.inset, in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct GroundedClaimRow: View {
    let claim: Claim
    let evidenceIndex: EvidenceIndex
    let onOpenEvidence: (EvidenceRef) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ClaimBadge(kind: claim.kind)
            Text(verbatim: claim.text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            EvidenceLinksView(
                ids: claim.evidenceIds,
                evidenceIndex: evidenceIndex,
                emptyLabel: claim.kind == .recommendation
                    ? "Recommendation is not evidence-backed"
                    : "No supporting evidence",
                onOpen: onOpenEvidence
            )
        }
        .padding(.vertical, 4)
    }
}
#endif
