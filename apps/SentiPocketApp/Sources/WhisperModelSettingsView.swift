import Foundation
import SwiftUI

@MainActor
struct WhisperModelSettingsView: View {
    @ObservedObject var coordinator: WhisperModelProvisioningCoordinator
    let onSignOut: (@MainActor () -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var presentsPicker = false
    @State private var stagedCopy: WhisperModelImportedCopy?
    @State private var presentsInstallConfirmation = false
    @State private var confirmsRemoval = false

    init(
        coordinator: WhisperModelProvisioningCoordinator,
        onSignOut: (@MainActor () -> Void)? = nil
    ) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        self.onSignOut = onSignOut
    }

    var body: some View {
        NavigationStack {
            Form {
                modelStatusSection
                modelActionsSection
                accountSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $presentsPicker, onDismiss: pickerDidDismiss) {
            WhisperModelDocumentPicker(
                onSelection: { importedCopy in
                    discardStagedCopy()
                    stagedCopy = importedCopy
                    presentsPicker = false
                },
                onCancel: {
                    discardStagedCopy()
                    presentsPicker = false
                }
            )
        }
        .sheet(
            isPresented: $presentsInstallConfirmation,
            onDismiss: discardStagedCopy
        ) {
            WhisperModelInstallConfirmationView(
                fileName: WhisperModelProvisioningCoordinator.requiredFileName,
                onInstall: installStagedCopy,
                onCancel: { presentsInstallConfirmation = false }
            )
        }
        .confirmationDialog(
            "Remove on-device speech model?",
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Model", role: .destructive) {
                _ = coordinator.removeConfirmedModel()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This durably removes the private model copy for future calls. A call that already loaded the model in memory may finish using it.")
        }
        .alert(
            coordinator.state.notice?.title ?? "On-device speech",
            isPresented: noticeIsPresented
        ) {
            Button("OK") { coordinator.dismissNotice() }
        } message: {
            Text(coordinator.state.notice?.detail ?? "")
        }
        .onDisappear { discardStagedCopy() }
    }

    private var modelStatusSection: some View {
        Section("On-device speech") {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: statusImage)
                    .foregroundStyle(statusColor)
                    .font(.title2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if coordinator.state.availability == .checking
                    || coordinator.state.activity == .verifying
                    || coordinator.state.activity == .cancelling {
                    ProgressView()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.whisper.status")

            installProgress
        }
    }

    @ViewBuilder
    private var installProgress: some View {
        if case .installing(let progress) = coordinator.state.activity {
            switch progress {
            case .copying(let completed, let total):
                ProgressView(value: Double(completed), total: Double(total)) {
                    Text("Copying model")
                } currentValueLabel: {
                    Text(Self.byteProgress(completed: completed, total: total))
                }
                .accessibilityIdentifier("settings.whisper.copy-progress")
            case .verifying:
                ProgressView("Verifying model integrity")
            case .finishing:
                ProgressView("Finishing private installation")
            case nil:
                ProgressView("Preparing private copy")
            }
        }
    }

    private var modelActionsSection: some View {
        Section {
            Button {
                discardStagedCopy()
                presentsPicker = true
            } label: {
                Label(importButtonTitle, systemImage: "square.and.arrow.down")
            }
            .disabled(!canBeginMutation)
            .accessibilityIdentifier("settings.whisper.choose-file")

            if case .installing = coordinator.state.activity {
                Button(role: .cancel) {
                    _ = coordinator.cancelInstallation()
                } label: {
                    Label("Cancel Import", systemImage: "xmark.circle")
                }
                .accessibilityIdentifier("settings.whisper.cancel-import")
            }

            if canOfferRemoval {
                Button(role: .destructive) {
                    confirmsRemoval = true
                } label: {
                    Label("Remove Model", systemImage: "trash")
                }
                .disabled(!canBeginMutation)
                .accessibilityIdentifier("settings.whisper.remove")
            }

            Button {
                _ = coordinator.refresh()
            } label: {
                Label("Verify Again", systemImage: "checkmark.shield")
            }
            .disabled(!canBeginMutation)
            .accessibilityIdentifier("settings.whisper.refresh")
        } header: {
            Text("Model file")
        } footer: {
            Text("Required file: \(WhisperModelProvisioningCoordinator.requiredFileName) (about \(Self.requiredSizeText)). Senti Pocket has no model downloader; choose a file already available in Files. The selected source location is never persisted.")
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        if let onSignOut {
            Section("Account") {
                Button("Sign out on this device", role: .destructive) {
                    dismiss()
                    onSignOut()
                }
                .accessibilityIdentifier("settings.account.sign-out")
            }
        }
    }

    private var canBeginMutation: Bool {
        coordinator.state.activity == .idle && coordinator.state.availability != .checking
    }

    private var canOfferRemoval: Bool {
        switch coordinator.state.availability {
        case .installed, .unusable: return true
        case .checking, .notInstalled, .unavailable: return false
        }
    }

    private var importButtonTitle: String {
        canOfferRemoval ? "Replace Model" : "Choose Model File"
    }

    private var statusTitle: String {
        switch coordinator.state.activity {
        case .installing: return "Installing model"
        case .verifying: return "Verifying model"
        case .cancelling: return "Reconciling cancelled import"
        case .removing: return "Removing model"
        case .idle:
            switch coordinator.state.availability {
            case .checking: return "Checking model"
            case .notInstalled: return "Model not installed"
            case .installed: return "Model installed and verified"
            case .unusable: return "Model needs replacement"
            case .unavailable: return "Model status unavailable"
            }
        }
    }

    private var statusDetail: String {
        switch coordinator.state.activity {
        case .installing:
            return "Copying into private storage before full size and SHA-256 verification."
        case .verifying:
            return "Reading the complete private model copy before reporting readiness."
        case .cancelling:
            return "Waiting for safe cleanup, then checking the model that is actually installed."
        case .removing:
            return "Removing and synchronizing the private model copy for future calls."
        case .idle:
            switch coordinator.state.availability {
            case .checking:
                return "Checking the complete private model copy."
            case .notInstalled:
                return "Import the pinned base English model to enable on-device speech on future calls."
            case .installed:
                return "The pinned model passed a fresh full integrity verification."
            case .unusable:
                return "A private copy exists but failed the pinned integrity or protection policy."
            case .unavailable:
                return "Readiness is not claimed because private storage could not be fully verified."
            }
        }
    }

    private var statusImage: String {
        switch coordinator.state.availability {
        case .checking: return "checkmark.shield"
        case .notInstalled: return "arrow.down.circle"
        case .installed: return "checkmark.shield.fill"
        case .unusable: return "exclamationmark.shield.fill"
        case .unavailable: return "questionmark.folder"
        }
    }

    private var statusColor: Color {
        switch coordinator.state.availability {
        case .installed: return .green
        case .unusable: return .orange
        case .unavailable: return .red
        case .checking, .notInstalled: return .secondary
        }
    }

    private var noticeIsPresented: Binding<Bool> {
        Binding(
            get: { coordinator.state.notice != nil },
            set: { isPresented in
                if !isPresented {
                    coordinator.dismissNotice()
                }
            }
        )
    }

    private func pickerDidDismiss() {
        guard stagedCopy != nil else { return }
        presentsInstallConfirmation = true
    }

    private func installStagedCopy() {
        guard let importedCopy = stagedCopy else {
            presentsInstallConfirmation = false
            return
        }
        stagedCopy = nil
        presentsInstallConfirmation = false
        _ = coordinator.installConfirmedCopy(importedCopy)
    }

    private func discardStagedCopy() {
        stagedCopy?.discard()
        stagedCopy = nil
    }

    private static var requiredSizeText: String {
        ByteCountFormatter.string(
            fromByteCount: WhisperModelProvisioningCoordinator.requiredByteCount,
            countStyle: .file
        )
    }

    private static func byteProgress(completed: Int64, total: Int64) -> String {
        let completedText = ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)
        let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return "\(completedText) of \(totalText)"
    }
}

@MainActor
private struct WhisperModelInstallConfirmationView: View {
    let fileName: String
    let onInstall: @MainActor () -> Void
    let onCancel: @MainActor () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 42))
                        .foregroundStyle(.blue)
                        .accessibilityHidden(true)
                    Text("Install on-device speech model?")
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                    Text("Senti Pocket will privately copy and fully verify \(fileName). The selected source location is never displayed or persisted.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Install Model", action: onInstall)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .accessibilityIdentifier("settings.whisper.confirm-install")
                    Button("Cancel", role: .cancel, action: onCancel)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
