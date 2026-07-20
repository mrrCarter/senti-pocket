#if canImport(SwiftUI)
import SwiftUI

public struct SessionListView: View {
    private let state: SessionListPresentationState
    private let send: (PocketProductIntent) -> Void

    public init(state: SessionListPresentationState, send: @escaping (PocketProductIntent) -> Void) {
        self.state = state
        self.send = send
    }

    public var body: some View {
        Group {
            if state.rows.isEmpty {
                emptyOrFailure
            } else {
                sessionList
            }
        }
        .navigationTitle("Sessions")
        .accessibilityIdentifier("pocket.sessions.screen")
        .pocketCanvas()
    }

    private var sessionList: some View {
        List {
            Section {
                SessionProvenanceBanner(provenance: state.provenance)
            }
            .listRowBackground(PocketPalette.raised)

            if let failure = state.failure {
                Section {
                    failureRow(failure)
                }
                .listRowBackground(PocketPalette.raised)
            }

            Section("Your sessions") {
                ForEach(state.rows) { row in
                    Button { send(.selectSession(sessionId: row.id)) } label: {
                        SessionRow(row: row)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("pocket.sessions.row.\(row.id)")
                    .accessibilityHint("Opens this session")
                    .listRowBackground(PocketPalette.raised)
                }
            }

            if state.hasMore {
                Section {
                    Button("Load more sessions") { send(.loadMoreSessions) }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .accessibilityIdentifier("pocket.sessions.load-more")
                }
                .listRowBackground(PocketPalette.raised)
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { send(.refreshSessions) }
        .overlay {
            if state.isRefreshing {
                ProgressView("Refreshing sessions")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("pocket.sessions.refreshing")
            }
        }
    }

    private var emptyOrFailure: some View {
        ScrollView {
            VStack(spacing: 16) {
                SessionProvenanceBanner(provenance: state.provenance)

                Image(systemName: state.failure == nil ? "rectangle.stack" : "exclamationmark.triangle.fill")
                    .font(.system(size: 46))
                    .foregroundStyle(state.failure == nil ? PocketPalette.accent : PocketPalette.warning)
                    .accessibilityHidden(true)

                Text(state.failure?.title ?? emptyTitle)
                    .font(.title2.bold())
                Text(state.failure?.detail ?? emptyDetail)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Try again") { send(.refreshSessions) }
                    .buttonStyle(.borderedProminent)
                    .tint(PocketPalette.accent)
                    .accessibilityIdentifier("pocket.sessions.retry")
            }
            .padding(28)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private var emptyTitle: String {
        switch state.provenance {
        case .network: return "No sessions yet"
        case .cache: return "No cached sessions"
        case .fixture: return "No preview sessions"
        case .unavailable: return "Sessions unavailable"
        }
    }

    private var emptyDetail: String {
        switch state.provenance {
        case .network: return "Sessions you create or join will appear here."
        case .cache: return "Reconnect to refresh your authorized sessions."
        case .fixture: return "This build has no live session data."
        case .unavailable: return "Sign in and connect to Senti to load your sessions."
        }
    }

    private func failureRow(_ failure: SessionLoadFailure) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.title).font(.headline)
                Text(failure.detail)
                    .font(.subheadline)
                    .foregroundStyle(PocketPalette.textSecondary)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PocketPalette.warning)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SessionRow: View {
    let row: SessionRowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    title
                    Spacer(minLength: 10)
                    status
                }
                VStack(alignment: .leading, spacing: 5) {
                    title
                    status
                }
            }

            if let summary = row.summary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .lineLimit(3)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    countLabels
                }
                VStack(alignment: .leading, spacing: 5) {
                    countLabels
                }
            }
            .font(.caption)
            .foregroundStyle(PocketPalette.textSecondary)

            HStack {
                Text(row.membershipRoleLabel)
                Spacer(minLength: 8)
                timestamp(row.lastActivity)
            }
            .font(.caption)
            .foregroundStyle(PocketPalette.textSecondary)

            Text(verbatim: row.id)
                .font(.caption2.monospaced())
                .foregroundStyle(PocketPalette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private var title: some View {
        Text(row.title)
            .font(.headline)
            .foregroundStyle(PocketPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var status: some View {
        Text(row.statusLabel)
            .font(.caption.weight(.semibold))
            .foregroundStyle(PocketPalette.accent)
    }

    @ViewBuilder
    private var countLabels: some View {
        Label("\(row.agentCount) agents", systemImage: "person.2")
        Label("\(row.eventCount) events", systemImage: "text.bubble")
    }

    @ViewBuilder
    private func timestamp(_ timestamp: ParsedSessionTimestamp?) -> some View {
        if let date = timestamp?.date {
            Text(date, style: .relative)
        } else if let raw = timestamp?.raw {
            Text(verbatim: raw)
        } else {
            Text("No activity yet")
        }
    }
}

struct SessionProvenanceBanner: View {
    let provenance: SessionPresentationProvenance

    var body: some View {
        Label {
            Text(message)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pocket.sessions.provenance")
    }

    private var message: String {
        switch provenance {
        case .network(let lastUpdated):
            return "Live session data · updated \(lastUpdated.formatted(.relative(presentation: .named)))"
        case .cache(let cachedAt, let authenticationExpired):
            let suffix = authenticationExpired ? " · sign in again to refresh" : ""
            return "Offline copy · cached \(cachedAt.formatted(.relative(presentation: .named)))\(suffix)"
        case .fixture:
            return "Preview data · not live"
        case .unavailable:
            return "No authorized session source"
        }
    }

    private var icon: String {
        switch provenance {
        case .network: return "network"
        case .cache: return "arrow.down.circle"
        case .fixture: return "doc.text.magnifyingglass"
        case .unavailable: return "lock.slash"
        }
    }

    private var color: Color {
        switch provenance {
        case .network: return PocketPalette.accent
        case .cache: return PocketPalette.warning
        case .fixture, .unavailable: return PocketPalette.textSecondary
        }
    }
}
#endif
