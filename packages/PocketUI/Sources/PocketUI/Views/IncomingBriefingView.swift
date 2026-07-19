#if canImport(SwiftUI)
import SwiftUI

public struct IncomingBriefingView: View {
    private let state: IncomingBriefingState
    private let connectivity: PocketConnectivity
    private let send: (PocketUIIntent) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    public init(
        state: IncomingBriefingState,
        connectivity: PocketConnectivity,
        send: @escaping (PocketUIIntent) -> Void
    ) {
        self.state = state
        self.connectivity = connectivity
        self.send = send
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                ConnectivityBanner(connectivity: connectivity)

                Spacer(minLength: 12)
                callMark

                VStack(spacing: 7) {
                    Text("INCOMING CHECKPOINT")
                        .font(.caption.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(PocketPalette.textSecondary)

                    Text("Senti is calling")
                        .font(.largeTitle.weight(.bold))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)

                    Text(state.sessionDisplayName ?? "Agent checkpoint")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(PocketPalette.textSecondary)
                        .multilineTextAlignment(.center)
                }

                briefingPreview

                if let failureReason = state.integrity.failureReason {
                    Label(
                        "Briefing blocked. Integrity verification is unavailable or failed: \(failureReason)",
                        systemImage: "exclamationmark.shield.fill"
                    )
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PocketPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .pocketCard()
                    .accessibilityAddTraits(.isHeader)
                }

                callActions
            }
            .padding(20)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier(PocketAccessibilityID.incomingScreen)
        .navigationBarBackButtonHidden(true)
        .pocketCanvas()
        .onAppear {
            if !reduceMotion { pulse = true }
        }
        .onChange(of: reduceMotion) { shouldReduce in
            pulse = !shouldReduce
        }
    }

    private var callMark: some View {
        ZStack {
            Circle()
                .stroke(PocketPalette.accent.opacity(0.22), lineWidth: 2)
                .frame(width: 152, height: 152)
                .scaleEffect(pulse ? 1.18 : 0.94)
                .opacity(reduceMotion ? 0.6 : (pulse ? 0.08 : 0.55))
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 1.25).repeatForever(autoreverses: true),
                    value: pulse
                )
            Circle()
                .fill(PocketPalette.accent)
                .frame(width: 116, height: 116)
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(Color.white)
        }
        .accessibilityHidden(true)
    }

    private var briefingPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            IntegrityBadge(integrity: state.integrity)

            if state.integrity.allowsBriefing {
                Text(verbatim: state.bundle.summary.headline)
                    .font(.title2.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        briefingSessionLabel
                        Text("·")
                            .accessibilityHidden(true)
                        briefingSequenceLabel
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        briefingSessionLabel
                        briefingSequenceLabel
                    }
                }
                .font(.caption)
                .foregroundStyle(PocketPalette.textSecondary)
            } else {
                Text("Checkpoint content hidden")
                    .font(.title3.weight(.semibold))
                Text("Senti will not display or narrate content until integrity verification succeeds.")
                    .font(.body)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pocketCard()
    }

    private var briefingSessionLabel: some View {
        HStack(spacing: 4) {
            Text("Session")
            Text(verbatim: state.bundle.sessionId)
                .font(.caption.monospaced())
        }
    }

    private var briefingSequenceLabel: some View {
        Text("Sequences \(state.bundle.sequenceStart)–\(state.bundle.sequenceEnd)")
            .monospacedDigit()
    }

    private var callActions: some View {
        let context = CheckpointContext(bundle: state.bundle)
        return VStack(spacing: 12) {
            Button {
                send(.answer(context))
            } label: {
                Label("Answer", systemImage: "phone.fill")
                    .font(.title3.weight(.bold))
                    .frame(maxWidth: .infinity, minHeight: 58)
            }
            .buttonStyle(.borderedProminent)
            .tint(PocketPalette.accent)
            .accessibilityIdentifier(PocketAccessibilityID.answer)
            .accessibilityHint(
                state.integrity.allowsBriefing
                    ? "Starts the cached checkpoint briefing"
                    : "Unavailable until checkpoint integrity verification succeeds"
            )
            .disabled(!state.integrity.allowsBriefing)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    listenLaterButton(context: context)
                    snoozeMenu(context: context)
                }
                VStack(spacing: 12) {
                    listenLaterButton(context: context)
                    snoozeMenu(context: context)
                }
            }
        }
    }

    private func listenLaterButton(context: CheckpointContext) -> some View {
        Button {
            send(.listenLater(context))
        } label: {
            Label("Listen later", systemImage: "bookmark")
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(PocketAccessibilityID.listenLater)
    }

    private func snoozeMenu(context: CheckpointContext) -> some View {
        Menu {
            ForEach(SnoozeOption.allCases, id: \.self) { option in
                Button(option.title) {
                    send(.snooze(context, option))
                }
            }
        } label: {
            Label("Snooze", systemImage: "alarm")
                .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier(PocketAccessibilityID.snooze)
        .accessibilityHint("Choose how long to silence this briefing")
    }
}
#endif
