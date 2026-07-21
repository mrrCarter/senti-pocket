#if canImport(SwiftUI)
import Foundation
import SwiftUI

struct PushToTalkLifecycleState: Equatable, Sendable {
    private var beginRequested = false
    private var cancellationTombstone = false
    private var lateActivationEndDelivered = false
    private var endDeliveredForActiveCapture = false

    mutating func requestBegin() {
        beginRequested = true
        cancellationTombstone = false
        lateActivationEndDelivered = false
        endDeliveredForActiveCapture = false
    }

    /// Returns `true` when an activation arrived after its pending begin was cancelled and must be
    /// synchronously ended again. The tombstone remains set until an inactive acknowledgement or a
    /// new explicit begin, so duplicate active/lifecycle callbacks cannot reopen the capture.
    mutating func activeStateChanged(_ isActive: Bool) -> Bool {
        guard isActive else {
            beginRequested = false
            cancellationTombstone = false
            lateActivationEndDelivered = false
            endDeliveredForActiveCapture = false
            return false
        }

        beginRequested = false
        guard cancellationTombstone, !lateActivationEndDelivered else { return false }
        lateActivationEndDelivered = true
        endDeliveredForActiveCapture = true
        return true
    }

    mutating func takeEndRequest(isActive: Bool, touchIsDown: Bool) -> Bool {
        let captureMayBeActive = touchIsDown || beginRequested || isActive
        beginRequested = false
        guard captureMayBeActive, !endDeliveredForActiveCapture else { return false }
        if !isActive {
            cancellationTombstone = true
            lateActivationEndDelivered = false
        }
        endDeliveredForActiveCapture = true
        return true
    }
}

public struct PushToTalkControl: View {
    private let isActive: Bool
    private let onBegin: () -> Void
    private let onEnd: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var touchIsDown = false
    @State private var holdHandledThisActivation = false
    @State private var activationGeneration = 0
    @State private var captureLifecycle = PushToTalkLifecycleState()

    public init(
        isActive: Bool,
        onBegin: @escaping () -> Void,
        onEnd: @escaping () -> Void
    ) {
        self.isActive = isActive
        self.onBegin = onBegin
        self.onEnd = onEnd
    }

    public var body: some View {
        Button {
            // Accessibility activation and keyboard/Switch Control use a deterministic toggle. A physical
            // press is handled by the zero-distance drag below and suppresses this release activation.
            guard !holdHandledThisActivation else { return }
            if isActive {
                stopCaptureIfNeeded()
            } else {
                captureLifecycle.requestBegin()
                onBegin()
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: isActive ? "waveform.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 48, weight: .semibold))
                    .accessibilityHidden(true)
                Text(isActive ? "Release to ask" : "Hold to ask")
                    .font(.headline)
                Text(isActive ? "Listening on this iPhone" : "Hold, then release")
                    .font(.caption)
                    .foregroundStyle(Color.white)
            }
            .frame(maxWidth: .infinity, minHeight: 104)
            .foregroundStyle(Color.white)
            .background(
                (isActive ? PocketPalette.recording : PocketPalette.accent),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.5)
            }
            .scaleEffect(touchIsDown ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: touchIsDown)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !touchIsDown else { return }
                    activationGeneration &+= 1
                    touchIsDown = true
                    holdHandledThisActivation = true
                    captureLifecycle.requestBegin()
                    if !isActive { onBegin() }
                }
                .onEnded { _ in
                    stopCaptureIfNeeded()
                    let completedGeneration = activationGeneration
                    DispatchQueue.main.async {
                        guard activationGeneration == completedGeneration, !touchIsDown else { return }
                        holdHandledThisActivation = false
                    }
                }
        )
        .accessibilityIdentifier(PocketAccessibilityID.pushToTalk)
        .accessibilityLabel(isActive ? "Stop recording" : "Push to talk")
        .accessibilityValue(isActive ? "Listening" : "Not listening")
        .accessibilityHint(isActive ? "Double-tap to stop" : "Double-tap to start, or touch and hold")
        .onChange(of: isActive) { active in
            let shouldEndLateActivation = captureLifecycle.activeStateChanged(active)
            if !active {
                touchIsDown = false
            }
            if shouldEndLateActivation {
                touchIsDown = false
                onEnd()
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { stopCaptureIfNeeded() }
        }
        .onDisappear {
            stopCaptureIfNeeded()
        }
    }

    /// Idempotent for gesture end, scene transitions, and view removal. The recording coordinator remains
    /// responsible for independently cancelling/clearing capture on AVAudioSession interruptions and app lifecycle.
    private func stopCaptureIfNeeded() {
        let shouldEnd = captureLifecycle.takeEndRequest(isActive: isActive, touchIsDown: touchIsDown)
        touchIsDown = false
        if shouldEnd { onEnd() }
    }
}
#endif
