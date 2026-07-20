#if canImport(SwiftUI)
import SwiftUI
import PocketContracts

public struct CheckpointInboxView: View {
    private let state: CheckpointInboxState
    private let connectivity: PocketConnectivity
    private let send: (PocketUIIntent) -> Void

    public init(
        state: CheckpointInboxState,
        connectivity: PocketConnectivity,
        send: @escaping (PocketUIIntent) -> Void
    ) {
        self.state = state
        self.connectivity = connectivity
        self.send = send
    }

    public var body: some View {
        VStack(spacing: 0) {
            if connectivity != .online {
                ConnectivityBanner(connectivity: connectivity)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }

            Group {
                if state.isLoading && state.items.isEmpty {
                    loadingView
                } else if let errorMessage = state.errorMessage, state.items.isEmpty {
                    errorView(errorMessage)
                } else if state.items.isEmpty {
                    emptyView
                } else {
                    inboxList
                }
            }
        }
        .navigationTitle("Checkpoints")
        .accessibilityIdentifier(PocketAccessibilityID.inboxScreen)
        .pocketCanvas()
    }

    private var inboxList: some View {
        List {
            if let errorMessage = state.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(PocketPalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(PocketPalette.raised)
            }

            if !readyItems.isEmpty {
                Section("Ready to brief") {
                    ForEach(readyItems) { item in
                        checkpointRow(item)
                    }
                }
            }

            if !blockedItems.isEmpty {
                Section("Needs verification") {
                    ForEach(blockedItems) { item in
                        checkpointRow(item)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var readyItems: [CheckpointInboxItem] {
        state.items.filter { $0.integrity.allowsBriefing }
    }

    private var blockedItems: [CheckpointInboxItem] {
        state.items.filter { !$0.integrity.allowsBriefing }
    }

    private func checkpointRow(_ item: CheckpointInboxItem) -> some View {
        Button {
            send(.selectCheckpoint(CheckpointContext(bundle: item.bundle)))
        } label: {
            CheckpointInboxRow(item: item)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(PocketAccessibilityID.inboxItem(
            sessionId: item.bundle.sessionId,
            checkpointId: item.bundle.checkpointId
        ))
        .accessibilityHint(
            item.integrity.allowsBriefing
                ? "Opens this checkpoint briefing"
                : "Unavailable until checkpoint integrity verification succeeds"
        )
        .disabled(!item.integrity.allowsBriefing)
        .listRowBackground(PocketPalette.raised)
    }

    private var loadingView: some View {
        CheckpointInboxStatusPanel(
            eyebrow: "Checking rooms",
            title: "Looking for checkpoints",
            message: "Senti is checking the selected session for a signed checkpoint that needs your attention.",
            footnote: "Read-only sync. Nothing is posted from this screen.",
            footnoteSymbolName: "lock.fill",
            indicator: .progress,
            accessibilityIdentifier: PocketAccessibilityID.inboxLoading
        )
    }

    private var emptyView: some View {
        CheckpointInboxStatusPanel(
            eyebrow: "All caught up",
            title: "No active checkpoints",
            message: "The selected session has no checkpoint waiting for your response.",
            footnote: "Senti will call when your agents need a decision.",
            footnoteSymbolName: "bell.badge.fill",
            indicator: .symbol("checkmark.circle.fill"),
            accessibilityIdentifier: PocketAccessibilityID.inboxEmpty
        )
    }

    private func errorView(_ message: String) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(PocketPalette.warning)
                    .accessibilityHidden(true)
                Text("Checkpoints unavailable")
                    .font(.title2.weight(.bold))
                Text(message)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("End of error details")
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .accessibilityIdentifier(PocketAccessibilityID.inboxErrorEnd)
            }
            .padding(28)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier(PocketAccessibilityID.inboxError)
    }
}

private enum CheckpointInboxStatusIndicator {
    case progress
    case symbol(String)
}

private struct CheckpointInboxStatusPanel: View {
    let eyebrow: String
    let title: String
    let message: String
    let footnote: String
    let footnoteSymbolName: String
    let indicator: CheckpointInboxStatusIndicator
    let accessibilityIdentifier: String

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                statusSymbol

                Text(eyebrow)
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .tracking(1.1)
                    .foregroundStyle(PocketPalette.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(PocketPalette.accent.opacity(0.12), in: Capsule())

                VStack(spacing: 8) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(PocketPalette.textPrimary)

                    Text(message)
                        .font(.body)
                        .foregroundStyle(PocketPalette.textSecondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

                Divider()

                Label(footnote, systemImage: footnoteSymbolName)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(PocketPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .background(PocketPalette.raised, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(PocketPalette.separator.opacity(0.72), lineWidth: 0.5)
            }
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private var statusSymbol: some View {
        ZStack {
            Circle()
                .fill(PocketPalette.accent.opacity(0.12))
                .frame(width: 76, height: 76)

            switch indicator {
            case .progress:
                ProgressView()
                    .tint(PocketPalette.accent)
                    .scaleEffect(1.25)
                    .accessibilityLabel("Checking for checkpoints")
            case .symbol(let symbolName):
                Image(systemName: symbolName)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(PocketPalette.accent)
                    .accessibilityHidden(true)
            }
        }
    }
}

private struct CheckpointInboxRow: View {
    let item: CheckpointInboxItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                attentionLabel
                Spacer(minLength: 8)
                if item.cachedForOffline {
                    Label("Available offline", systemImage: "arrow.down.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(PocketPalette.accent)
                }
            }

            if item.integrity.allowsBriefing {
                Text(verbatim: item.bundle.summary.headline)
                    .font(.headline)
                    .foregroundStyle(PocketPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Sequences \(item.bundle.sequenceStart)–\(item.bundle.sequenceEnd)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(PocketPalette.textSecondary)

                Text(verbatim: item.bundle.sessionId)
                    .font(.caption.monospaced())
                    .foregroundStyle(PocketPalette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("Checkpoint content hidden")
                    .font(.headline)
                    .foregroundStyle(PocketPalette.danger)
                Text("Integrity verification unavailable or failed")
                    .font(.caption)
                    .foregroundStyle(PocketPalette.textSecondary)
            }

            HStack {
                IntegrityBadge(integrity: item.integrity)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .foregroundStyle(PocketPalette.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var attentionLabel: some View {
        switch item.attention {
        case .unheard:
            Label("New briefing", systemImage: "circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketPalette.accent)
        case .heard:
            Label("Heard", systemImage: "checkmark.circle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketPalette.textSecondary)
        case .listenLater:
            Label("Listen later", systemImage: "bookmark.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketPalette.listening)
        case .snoozed(let until):
            Label("Snoozed until \(until.formatted(date: .omitted, time: .shortened))", systemImage: "alarm.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketPalette.warning)
        }
    }
}
#endif
