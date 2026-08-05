import Darwin
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Ownership token for a single sandbox copy created by `UIDocumentPickerViewController` with
/// `asCopy: true`. Cleanup uses one `unlink` and refuses URLs outside the app container, so it
/// cannot recursively delete a directory or mutate a provider/open-mode document.
struct WhisperModelImportedCopy: Equatable, Sendable {
    let url: URL

    func discard() {
        guard url.isFileURL else { return }
        let lexicalCandidate = url.standardizedFileURL.path
        let resolvedCandidate = url.resolvingSymlinksInPath().standardizedFileURL.path
        let lexicalHome = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .standardizedFileURL.path
        let resolvedHome = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path
        guard (Self.isChild(lexicalCandidate, of: lexicalHome)
                || Self.isChild(lexicalCandidate, of: resolvedHome)),
              Self.isChild(resolvedCandidate, of: resolvedHome) else { return }
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            _ = Darwin.unlink(path)
        }
    }

    private static func isChild(_ candidate: String, of directory: String) -> Bool {
        let prefix = directory.hasSuffix("/") ? directory : directory + "/"
        return candidate.hasPrefix(prefix)
    }
}

/// UIKit is used deliberately because its initializer exposes the copy/import semantic that the
/// SwiftUI file-importer API does not. The picked URL is only staged for a later confirmation.
struct WhisperModelDocumentPicker: UIViewControllerRepresentable {
    static let acceptedContentTypes: [UTType] = [.data]
    static let importsAsCopy = true
    static let allowsMultipleSelection = false

    private let onSelection: @MainActor (WhisperModelImportedCopy) -> Void
    private let onCancel: @MainActor () -> Void

    init(
        onSelection: @escaping @MainActor (WhisperModelImportedCopy) -> Void,
        onCancel: @escaping @MainActor () -> Void
    ) {
        self.onSelection = onSelection
        self.onCancel = onCancel
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = Self.makePickerViewController()
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(
        _ uiViewController: UIDocumentPickerViewController,
        context: Context
    ) {}

    static func makePickerViewController() -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: acceptedContentTypes,
            asCopy: importsAsCopy
        )
        picker.allowsMultipleSelection = allowsMultipleSelection
        return picker
    }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onSelection: @MainActor (WhisperModelImportedCopy) -> Void
        private let onCancel: @MainActor () -> Void

        init(
            onSelection: @escaping @MainActor (WhisperModelImportedCopy) -> Void,
            onCancel: @escaping @MainActor () -> Void
        ) {
            self.onSelection = onSelection
            self.onCancel = onCancel
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard urls.count == 1, let selectedURL = urls.first else {
                for url in urls {
                    WhisperModelImportedCopy(url: url).discard()
                }
                onCancel()
                return
            }
            onSelection(WhisperModelImportedCopy(url: selectedURL))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}
