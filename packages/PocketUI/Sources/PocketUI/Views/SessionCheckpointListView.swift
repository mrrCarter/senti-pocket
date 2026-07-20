#if canImport(SwiftUI)
import SwiftUI

public struct SessionCheckpointListView: View {
    private let state: SessionCheckpointListPresentationState
    private let send: (PocketProductIntent) -> Void

    public init(
        state: SessionCheckpointListPresentationState,
        send: @escaping (PocketProductIntent) -> Void
    ) {
        self.state = state
        self.send = send
    }

    public var body: some View {
        Group {
            if state.rows.isEmpty {
                emptyOrFailure
            } else {
                checkpointList
            }
        }
        .navigationTitle("Room checkpoints")
        .accessibilityIdentifier("pocket.session-checkpoints.screen")
        .pocketCanvas()
    }

    private var checkpointList: some View {
        List {
            Section {
                SessionProvenanceBanner(provenance: state.provenance)
                trustBoundaryNotice
            }
            .listRowBackground(PocketPalette.raised)

            if let failure = state.failure {
                Section {
                    Label(failure.detail, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(PocketPalette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                }
                .listRowBackground(PocketPalette.raised)
            }

            Section("Checkpoints") {
                ForEach(state.rows) { row in
                    Button {
                        send(.openCheckpoint(sessionId: row.sessionId, checkpointId: row.checkpointId))
                    } label: {
                        SessionCheckpointRow(row: row)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(checkpointAccessibilityID(row))
                    .accessibilityHint("Opens this room checkpoint. It is not a signed Pocket briefing.")
                    .listRowBackground(PocketPalette.raised)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { send(.refreshCheckpoints(sessionId: state.sessionId)) }
        .overlay {
            if state.isRefreshing {
                ProgressView("Refreshing checkpoints")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("pocket.session-checkpoints.refreshing")
            }
        }
    }

    private var emptyOrFailure: some View {
        ScrollView {
            VStack(spacing: 16) {
                SessionProvenanceBanner(provenance: state.provenance)

                Image(systemName: state.failure == nil ? "tray.full" : "exclamationmark.triangle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(state.failure == nil ? PocketPalette.accent : PocketPalette.warning)
                    .accessibilityHidden(true)

                Text(state.failure?.title ?? "No room checkpoints")
                    .font(.title2.bold())
                Text(state.failure?.detail ?? "Checkpoints created in this session will appear here after an authorized sync.")
                    .foregroundStyle(PocketPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                trustBoundaryNotice

                Button("Try again") {
                    send(.refreshCheckpoints(sessionId: state.sessionId))
                }
                .buttonStyle(.borderedProminent)
                .tint(PocketPalette.accent)
                .accessibilityIdentifier("pocket.session-checkpoints.retry")
            }
            .padding(28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private var trustBoundaryNotice: some View {
        Label {
            Text("Room checkpoints are available through your membership. Only separately verified Senti briefings receive a signed-bundle badge.")
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "person.2")
                .foregroundStyle(PocketPalette.textSecondary)
        }
        .foregroundStyle(PocketPalette.textSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pocket.session-checkpoints.trust-notice")
    }

    private func checkpointAccessibilityID(_ row: SessionCheckpointRowPresentation) -> String {
        let session = row.sessionId
        let checkpoint = row.checkpointId
        return "pocket.session-checkpoints.row.\(session.utf8.count):\(session).\(checkpoint.utf8.count):\(checkpoint)"
    }
}

private struct SessionCheckpointRow: View {
    let row: SessionCheckpointRowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    title
                    Spacer(minLength: 10)
                    kind
                }
                VStack(alignment: .leading, spacing: 5) {
                    title
                    kind
                }
            }

            if let summary = row.summary {
                Text(summary)
                    .font(.body)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .lineLimit(4)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    sequence
                    grade
                }
                VStack(alignment: .leading, spacing: 5) {
                    sequence
                    grade
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    creator
                    Spacer(minLength: 8)
                    timestamp
                }
                VStack(alignment: .leading, spacing: 5) {
                    creator
                    timestamp
                }
            }
            .font(.caption)
            .foregroundStyle(PocketPalette.textSecondary)

            Text(row.trustNotice)
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var title: some View {
        Text(row.title)
            .font(.headline)
            .foregroundStyle(PocketPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var kind: some View {
        Text(row.kindLabel)
            .font(.caption.weight(.semibold))
            .foregroundStyle(PocketPalette.accent)
    }

    private var sequence: some View {
        Label(row.sequenceLabel, systemImage: "number")
            .font(.caption.monospacedDigit())
            .foregroundStyle(PocketPalette.textSecondary)
    }

    private var grade: some View {
        Label(row.gradeLabel, systemImage: "chart.bar.doc.horizontal")
            .font(.caption)
            .foregroundStyle(PocketPalette.textSecondary)
    }

    private var creator: some View {
        Text("Created by \(row.createdBy)")
    }

    @ViewBuilder
    private var timestamp: some View {
        if let date = row.createdAt.date {
            Text(date, style: .relative)
        } else {
            Text(verbatim: row.createdAt.raw)
        }
    }
}
#endif
