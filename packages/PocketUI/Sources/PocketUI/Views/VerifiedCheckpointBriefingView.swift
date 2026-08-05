import PocketCall
import PocketContracts

/// A presentation snapshot that can only be projected from the production trust-boundary type.
///
/// Keeping the initializer `VerifiedBundle`-only prevents membership-authorized checkpoint rows, decoded network
/// bytes, or caller-asserted integrity labels from entering the verified briefing surface.
struct VerifiedCheckpointBriefingPresentation: Equatable, Sendable {
    let verifiedBundle: VerifiedBundle
    let checkpointId: String
    let sessionId: String
    let sequenceStart: Int
    let sequenceEnd: Int
    let signingKeyId: String
    let summary: CheckpointSummary
    let evidenceCount: Int

    init(verifiedBundle: VerifiedBundle) {
        let bundle = verifiedBundle.bundle
        self.verifiedBundle = verifiedBundle
        self.checkpointId = bundle.checkpointId
        self.sessionId = bundle.sessionId
        self.sequenceStart = bundle.sequenceStart
        self.sequenceEnd = bundle.sequenceEnd
        self.signingKeyId = bundle.signingKeyId
        self.summary = bundle.summary
        self.evidenceCount = bundle.evidence.count
    }
}

#if canImport(SwiftUI)
import SwiftUI

/// Read-only rendering of one signature-verified checkpoint.
///
/// This view has no intent callback or lifecycle side effect: it cannot fetch, cache, narrate, reason, snooze,
/// propose, or write. The host must complete exact checkpoint transport and verification before it can construct the
/// sole public initializer.
public struct VerifiedCheckpointBriefingView: View {
    private let presentation: VerifiedCheckpointBriefingPresentation

    public init(verifiedBundle: VerifiedBundle) {
        self.presentation = VerifiedCheckpointBriefingPresentation(verifiedBundle: verifiedBundle)
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                verificationCard
                headlineCard

                ForEach(presentation.summary.perAgent, id: \.verifiedOpaqueIdentity) { agent in
                    agentCard(agent)
                }

                if !presentation.summary.risks.isEmpty {
                    boundedList(
                        title: "Risks",
                        systemImage: "exclamationmark.triangle.fill",
                        values: presentation.summary.risks,
                        accessibilityID: "pocket.verified-checkpoint.risks"
                    )
                }

                if !presentation.summary.blockers.isEmpty {
                    boundedList(
                        title: "Blockers",
                        systemImage: "hand.raised.fill",
                        values: presentation.summary.blockers,
                        accessibilityID: "pocket.verified-checkpoint.blockers"
                    )
                }
            }
            .padding(18)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Verified briefing")
        .accessibilityIdentifier("pocket.verified-checkpoint.screen")
        .pocketCanvas()
    }

    private var verificationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            IntegrityBadge(
                integrity: BundleIntegrityState(verifiedBundle: presentation.verifiedBundle)
            )

            Text("Signed checkpoint identity")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            identityRow("Session", value: presentation.sessionId)
            identityRow("Checkpoint", value: presentation.checkpointId)
            identityRow(
                "Sequence range",
                value: "\(presentation.sequenceStart)–\(presentation.sequenceEnd)"
            )
            identityRow("Signing key", value: presentation.signingKeyId)
            identityRow("Evidence references", value: String(presentation.evidenceCount))

            Text("Read-only. Every item below belongs to this exact signed checkpoint.")
                .font(.caption)
                .foregroundStyle(PocketPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .pocketCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pocket.verified-checkpoint.identity")
    }

    private var headlineCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PocketPalette.textSecondary)
            Text(verbatim: presentation.summary.headline)
                .font(.title2.weight(.semibold))
                .foregroundStyle(PocketPalette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pocketCard()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("pocket.verified-checkpoint.headline")
    }

    private func agentCard(_ agent: AgentSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(verbatim: agent.agentId)
                .font(.headline)
                .foregroundStyle(PocketPalette.textPrimary)
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)

            if !agent.summary.isEmpty {
                Text(verbatim: agent.summary)
                    .font(.body)
                    .foregroundStyle(PocketPalette.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(agent.claims, id: \.verifiedOpaqueIdentity) { claim in
                claimRow(claim, agentId: agent.agentId)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pocketCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(scopedAccessibilityID("agent", values: [agent.agentId]))
    }

    private func claimRow(_ claim: Claim, agentId: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ClaimBadge(kind: claim.kind)
            Text(verbatim: claim.text)
                .font(.body)
                .foregroundStyle(PocketPalette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !claim.evidenceIds.isEmpty {
                Label(
                    "\(claim.evidenceIds.count) signed evidence reference\(claim.evidenceIds.count == 1 ? "" : "s")",
                    systemImage: "link"
                )
                .font(.caption)
                .foregroundStyle(PocketPalette.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PocketPalette.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            scopedAccessibilityID("claim", values: [agentId, claim.id])
        )
    }

    private func boundedList(
        title: String,
        systemImage: String,
        values: [String],
        accessibilityID: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            ForEach(values.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 9) {
                    Text("•")
                        .accessibilityHidden(true)
                    Text(verbatim: values[index])
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pocketCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityID)
    }

    private func identityRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PocketPalette.textSecondary)
            Text(verbatim: value)
                .font(.caption.monospaced())
                .foregroundStyle(PocketPalette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func scopedAccessibilityID(_ kind: String, values: [String]) -> String {
        let identity = values.map { "\($0.utf8.count):\($0)" }.joined(separator: ".")
        return "pocket.verified-checkpoint.\(kind).\(identity)"
    }
}

private extension AgentSummary {
    var verifiedOpaqueIdentity: OpaqueUTF8Identity { OpaqueUTF8Identity(agentId) }
}

private extension Claim {
    var verifiedOpaqueIdentity: OpaqueUTF8Identity { OpaqueUTF8Identity(id) }
}
#endif
