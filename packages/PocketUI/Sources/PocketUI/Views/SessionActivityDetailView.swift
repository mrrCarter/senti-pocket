#if canImport(SwiftUI)
import Foundation
import PocketContracts
import SwiftUI

/// Full membership-authorized event presentation reached only from a validated visible Activity row.
public struct SessionEventDetailView: View {
    private let event: SessionEventRowPresentation
    private let provenance: SessionPresentationProvenance

    public init(
        event: SessionEventRowPresentation,
        provenance: SessionPresentationProvenance
    ) {
        self.event = event
        self.provenance = provenance
    }

    public var body: some View {
        List {
            Section {
                SessionProvenanceBanner(provenance: provenance)
                membershipNotice
            }
            .listRowBackground(PocketPalette.raised)

            Section("Event") {
                detail("Type", event.eventTypeLabel)
                detail("Author", event.author)
                detail("Sequence", "#\(event.sequenceId)", monospaced: true)
                detail("Event ID", event.id.eventId, monospaced: true)
                timestamp
            }
            .listRowBackground(PocketPalette.raised)

            if let text = event.text {
                Section("Message") {
                    Text(text)
                        .foregroundStyle(PocketPalette.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(PocketPalette.raised)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Event #\(event.sequenceId)")
        .accessibilityIdentifier("pocket.activity.event-detail")
        .pocketCanvas()
    }

    private var membershipNotice: some View {
        Label(
            "Available through your current session membership. This event is not a signed Pocket briefing.",
            systemImage: "person.2"
        )
        .font(.subheadline)
        .foregroundStyle(PocketPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var timestamp: some View {
        if let date = event.timestamp.date {
            detail("Received", date.formatted(date: .abbreviated, time: .standard))
        } else {
            detail("Received", event.timestamp.raw, monospaced: true)
        }
    }

    private func detail(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        LabeledContent(label) {
            Text(verbatim: value)
                .font(monospaced ? Font.body.monospaced() : Font.body)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}

/// Full membership-authorized action presentation reached only from a validated visible Activity row.
public struct SessionActionDetailView: View {
    private let action: SessionActionRowPresentation
    private let provenance: SessionPresentationProvenance

    public init(
        action: SessionActionRowPresentation,
        provenance: SessionPresentationProvenance
    ) {
        self.action = action
        self.provenance = provenance
    }

    public var body: some View {
        List {
            Section {
                SessionProvenanceBanner(provenance: provenance)
                membershipNotice
            }
            .listRowBackground(PocketPalette.raised)

            Section("Action") {
                detail("Type", action.actionTypeLabel)
                detail("Actor", action.actor)
                detail("Target", action.targetLabel, monospaced: true)
                detail("Action ID", action.id.actionId, monospaced: true)
                timestamp
            }
            .listRowBackground(PocketPalette.raised)

            if let note = action.note {
                Section("Note") {
                    Text(note)
                        .foregroundStyle(PocketPalette.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowBackground(PocketPalette.raised)
            }
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(action.actionTypeLabel)
        .accessibilityIdentifier("pocket.activity.action-detail")
        .pocketCanvas()
    }

    private var membershipNotice: some View {
        Label(
            "Available through your current session membership. This action is not a cryptographic receipt.",
            systemImage: "person.2"
        )
        .font(.subheadline)
        .foregroundStyle(PocketPalette.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var timestamp: some View {
        if let date = action.createdAt.date {
            detail("Created", date.formatted(date: .abbreviated, time: .standard))
        } else {
            detail("Created", action.createdAt.raw, monospaced: true)
        }
    }

    private func detail(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        LabeledContent(label) {
            Text(verbatim: value)
                .font(monospaced ? Font.body.monospaced() : Font.body)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
#endif
