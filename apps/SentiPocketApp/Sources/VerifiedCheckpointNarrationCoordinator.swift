import Combine
import Foundation
import PocketCall
import PocketContracts
import PocketUI
import PocketVoice
import SwiftUI

/// Exact identity for one signature-verified narration surface. Including the signature prevents SwiftUI from
/// reusing a coordinator when the gateway returns newly signed content under the same checkpoint identifier.
struct VerifiedCheckpointNarrationIdentity: Hashable, Sendable {
    private let sessionId: String
    private let checkpointId: String
    private let signingKeyId: String
    private let signature: String

    init(verifiedBundle: VerifiedBundle) {
        let bundle = verifiedBundle.bundle
        sessionId = bundle.sessionId
        checkpointId = bundle.checkpointId
        signingKeyId = bundle.signingKeyId
        signature = bundle.signature
    }
}

/// A bounded, deterministic speech projection whose only initializer requires the production trust-boundary type.
/// No raw bundle, decoded response, membership row, or arbitrary caller-supplied text can become a narration plan.
struct VerifiedCheckpointNarrationPlan: Equatable, Sendable {
    static let maximumCharacterCount = 4_000
    static let maximumContentSegments = 64
    static let omittedContentNotice = "Additional verified details remain on screen."

    let identity: VerifiedCheckpointNarrationIdentity
    let spokenText: String

    init(verifiedBundle: VerifiedBundle) {
        identity = VerifiedCheckpointNarrationIdentity(verifiedBundle: verifiedBundle)
        spokenText = Self.project(verifiedBundle)
    }

    private static func project(_ verifiedBundle: VerifiedBundle) -> String {
        let bundle = verifiedBundle.bundle
        var segments = [
            "Verified checkpoint.",
            bundle.summary.headline
        ]

        for agent in bundle.summary.perAgent {
            segments.append("Agent \(agent.agentId).")
            if !agent.summary.isEmpty {
                segments.append(agent.summary)
            }
            for claim in agent.claims {
                segments.append("\(spokenLabel(for: claim.kind)): \(claim.text)")
            }
        }

        if !bundle.summary.risks.isEmpty {
            segments.append("Risks.")
            segments.append(contentsOf: bundle.summary.risks)
        }
        if !bundle.summary.blockers.isEmpty {
            segments.append("Blockers.")
            segments.append(contentsOf: bundle.summary.blockers)
        }

        return boundedText(segments)
    }

    /// Keeps both work and speech bounded. It admits only complete substantive segments; when the signed briefing is
    /// larger than the audio budget, the visible verified view remains authoritative and narration says so honestly.
    private static func boundedText(_ rawSegments: [String]) -> String {
        let normalized = rawSegments.compactMap { raw -> String? in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        let limited = Array(normalized.prefix(maximumContentSegments))
        var admitted: [String] = []
        var omitted = normalized.count > limited.count

        for segment in limited {
            let candidate = (admitted + [segment]).joined(separator: " ")
            if candidate.count <= maximumCharacterCount {
                admitted.append(segment)
            } else {
                omitted = true
                break
            }
        }

        guard omitted else { return admitted.joined(separator: " ") }

        while (admitted + [omittedContentNotice])
            .joined(separator: " ")
            .count > maximumCharacterCount,
            !admitted.isEmpty {
            admitted.removeLast()
        }
        admitted.append(omittedContentNotice)
        return admitted.joined(separator: " ")
    }

    private static func spokenLabel(for kind: ClaimKind) -> String {
        switch kind {
        case .fact: return "Fact"
        case .inference: return "Inference"
        case .recommendation: return "Recommendation"
        }
    }
}

enum VerifiedCheckpointNarrationPhase: Equatable, Sendable {
    case idle
    case speaking
    case completed
    case failed

    var isSpeaking: Bool { self == .speaking }
}

/// Release-capable, listen-only owner for one exact verified briefing.
///
/// Every suspended completion is fenced by both exact signed identity and a lifecycle revision. Revocation changes
/// state synchronously, cancels the operation, and queues a stop through PocketVoice's serialized audio-session path.
@MainActor
final class VerifiedCheckpointNarrationCoordinator: ObservableObject {
    @Published private(set) var phase: VerifiedCheckpointNarrationPhase = .idle

    let plan: VerifiedCheckpointNarrationPlan

    private struct OperationToken: Equatable, Sendable {
        let identity: VerifiedCheckpointNarrationIdentity
        let lifecycleRevision: UInt64
        let requestId: UUID
    }

    private let synthesizer: any SpeechSynthesizer
    private var lifecycleRevision: UInt64 = 0
    private var activeRequestId: UUID?
    private var operation: Task<Void, Never>?
    private var stopBarrier: Task<Void, Never>?

    init(
        verifiedBundle: VerifiedBundle,
        synthesizer: any SpeechSynthesizer = AVSpeechSynthesizerAdapter()
    ) {
        plan = VerifiedCheckpointNarrationPlan(verifiedBundle: verifiedBundle)
        self.synthesizer = synthesizer
    }

    deinit {
        // PocketVoice's cancellation handler stops active AVSpeech and releases its audio-session lease. SwiftUI's
        // onDisappear performs the explicit stop; this is the final ownership backstop for abrupt teardown.
        operation?.cancel()
    }

    @discardableResult
    func start() -> Task<Void, Never>? {
        fenceActiveOperation()

        let requestId = UUID()
        guard let request = try? SpeechSynthesisRequest(
            id: requestId,
            text: plan.spokenText,
            tone: .neutral
        ) else {
            phase = .failed
            return nil
        }

        phase = .speaking
        let token = OperationToken(
            identity: plan.identity,
            lifecycleRevision: lifecycleRevision,
            requestId: requestId
        )
        activeRequestId = requestId
        let barrier = scheduleStop()
        let synthesizer = self.synthesizer
        let task = Task { @MainActor [weak self] in
            await barrier.value
            guard let self, self.operationMatches(token), !Task.isCancelled else { return }

            do {
                _ = try await synthesizer.speak(request)
                guard self.operationMatches(token), !Task.isCancelled else { return }
                self.phase = .completed
                self.activeRequestId = nil
                self.operation = nil
            } catch {
                guard self.operationMatches(token), !Task.isCancelled else { return }
                self.phase = (error as? VoiceError) == .cancelled ? .idle : .failed
                self.activeRequestId = nil
                self.operation = nil
            }
        }
        operation = task
        return task
    }

    /// Used by Stop, Done, view disappearance, scene deactivation, selection change, and authentication teardown.
    @discardableResult
    func revoke() -> Task<Void, Never> {
        fenceActiveOperation()
        phase = .idle
        return scheduleStop()
    }

    private func operationMatches(_ token: OperationToken) -> Bool {
        token.identity == plan.identity
            && token.lifecycleRevision == lifecycleRevision
            && token.requestId == activeRequestId
    }

    private func fenceActiveOperation() {
        operation?.cancel()
        operation = nil
        activeRequestId = nil
        lifecycleRevision &+= 1
    }

    /// Serializing stop barriers prevents a quick Stop -> Listen sequence from letting an older stop cancel newer audio.
    private func scheduleStop() -> Task<Void, Never> {
        let predecessor = stopBarrier
        let synthesizer = self.synthesizer
        let barrier = Task {
            if let predecessor { await predecessor.value }
            await synthesizer.stop()
        }
        stopBarrier = barrier
        return barrier
    }
}

/// Auth/session/checkpoint owners hold this relay and synchronously fence narration before clearing a ready bundle.
/// The coordinator remains weakly held so the relay cannot extend protected-content or audio lifetime.
@MainActor
final class VerifiedCheckpointNarrationRevocationRelay: ObservableObject {
    private weak var coordinator: VerifiedCheckpointNarrationCoordinator?

    func install(_ coordinator: VerifiedCheckpointNarrationCoordinator) {
        self.coordinator = coordinator
    }

    func remove(_ coordinator: VerifiedCheckpointNarrationCoordinator) {
        guard self.coordinator === coordinator else { return }
        self.coordinator = nil
    }

    @discardableResult
    func revoke() -> Task<Void, Never>? {
        coordinator?.revoke()
    }
}

/// Side-effecting host kept outside PocketUI's pure VerifiedBundle-only renderer. The host adds only local
/// listen/stop controls; it has no network, microphone, reasoning, cache, proposal, write, or persistence dependency.
struct VerifiedCheckpointNarrationView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var dialHost: DialHost
    @StateObject private var narration: VerifiedCheckpointNarrationCoordinator
    @State private var audioRevokerId: UUID?

    private let verifiedBundle: VerifiedBundle
    @ObservedObject private var revocationRelay: VerifiedCheckpointNarrationRevocationRelay
    private let onDone: @MainActor () -> Void

    init(
        verifiedBundle: VerifiedBundle,
        revocationRelay: VerifiedCheckpointNarrationRevocationRelay,
        onDone: @escaping @MainActor () -> Void
    ) {
        self.verifiedBundle = verifiedBundle
        _revocationRelay = ObservedObject(wrappedValue: revocationRelay)
        self.onDone = onDone
        _narration = StateObject(wrappedValue: VerifiedCheckpointNarrationCoordinator(
            verifiedBundle: verifiedBundle
        ))
    }

    var body: some View {
        VerifiedCheckpointBriefingView(verifiedBundle: verifiedBundle)
            .safeAreaInset(edge: .bottom) { controls }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        _ = narration.revoke()
                        onDone()
                    }
                    .accessibilityIdentifier("pocket.verified-checkpoint.done")
                }
            }
            .onAppear { installRevocationOwners() }
            .onDisappear { removeRevocationOwners() }
            .onChange(of: scenePhase) { phase in
                if phase != .active { _ = narration.revoke() }
            }
            .onChange(of: dialHost.callAudioReservationIsActive) { isActive in
                if isActive { _ = narration.revoke() }
            }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button {
                if !dialHost.permitsPreemptibleAudio {
                    _ = narration.revoke()
                } else if narration.phase.isSpeaking {
                    _ = narration.revoke()
                } else {
                    _ = narration.start()
                }
            } label: {
                Label(
                    narration.phase.isSpeaking ? "Stop" : listenTitle,
                    systemImage: narration.phase.isSpeaking ? "stop.fill" : "speaker.wave.2.fill"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(!dialHost.permitsPreemptibleAudio)
            .accessibilityIdentifier("pocket.verified-checkpoint.narration-toggle")

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("pocket.verified-checkpoint.narration-status")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private var listenTitle: String {
        narration.phase == .completed ? "Listen again" : "Listen"
    }

    private var statusText: String {
        if !dialHost.permitsPreemptibleAudio {
            return "Senti call audio has priority"
        }
        switch narration.phase {
        case .idle: return "On-device, read-only narration"
        case .speaking: return "Reading this exact verified checkpoint"
        case .completed: return "Verified briefing finished"
        case .failed: return "Narration unavailable. The verified briefing remains on screen."
        }
    }

    private func installRevocationOwners() {
        revocationRelay.install(narration)
        guard audioRevokerId == nil else { return }
        let coordinator = narration
        audioRevokerId = dialHost.installPreemptibleAudioRevoker { [weak coordinator] in
            coordinator?.revoke()
        }
    }

    private func removeRevocationOwners() {
        if let audioRevokerId {
            dialHost.removePreemptibleAudioRevoker(audioRevokerId)
            self.audioRevokerId = nil
        } else {
            _ = narration.revoke()
        }
        revocationRelay.remove(narration)
    }
}
