import Foundation
import UniformTypeIdentifiers
import UIKit
import XCTest
@testable import SentiPocketApp

@MainActor
final class WhisperModelDocumentPickerTests: XCTestCase {
    func test_pickerUsesGenericDataCopyImportAndDisablesMultipleSelection() {
        XCTAssertEqual(
            WhisperModelDocumentPicker.acceptedContentTypes.map(\.identifier),
            [UTType.data.identifier]
        )
        XCTAssertTrue(WhisperModelDocumentPicker.importsAsCopy)
        XCTAssertFalse(WhisperModelDocumentPicker.allowsMultipleSelection)

        let picker = WhisperModelDocumentPicker.makePickerViewController()
        XCTAssertFalse(picker.allowsMultipleSelection)
    }

    func test_exactlyOneSelectionStagesExactURLWithoutAnyStoreDependency() {
        var selectedCopies: [WhisperModelImportedCopy] = []
        var cancellationCount = 0
        let representable = WhisperModelDocumentPicker(
            onSelection: { selectedCopies.append($0) },
            onCancel: { cancellationCount += 1 }
        )
        let bridge = representable.makeCoordinator()
        let picker = WhisperModelDocumentPicker.makePickerViewController()
        let selectedURL = URL(fileURLWithPath: "/provider-copy/ggml-base.en.bin")

        bridge.documentPicker(picker, didPickDocumentsAt: [selectedURL])

        XCTAssertEqual(selectedCopies.map(\.url), [selectedURL])
        XCTAssertEqual(cancellationCount, 0)
    }

    func test_cancelIsFirstClassAndStagesNothing() {
        var selectedCopies: [WhisperModelImportedCopy] = []
        var cancellationCount = 0
        let representable = WhisperModelDocumentPicker(
            onSelection: { selectedCopies.append($0) },
            onCancel: { cancellationCount += 1 }
        )
        let bridge = representable.makeCoordinator()
        let picker = WhisperModelDocumentPicker.makePickerViewController()

        bridge.documentPickerWasCancelled(picker)

        XCTAssertTrue(selectedCopies.isEmpty)
        XCTAssertEqual(cancellationCount, 1)
    }

    func test_zeroOrMultipleReturnedURLsFailClosedAsCancellation() throws {
        var selectedCopies: [WhisperModelImportedCopy] = []
        var cancellationCount = 0
        let representable = WhisperModelDocumentPicker(
            onSelection: { selectedCopies.append($0) },
            onCancel: { cancellationCount += 1 }
        )
        let bridge = representable.makeCoordinator()
        let picker = WhisperModelDocumentPicker.makePickerViewController()
        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        let secondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try Data([0x01]).write(to: firstURL, options: .atomic)
        try Data([0x02]).write(to: secondURL, options: .atomic)

        bridge.documentPicker(picker, didPickDocumentsAt: [])
        bridge.documentPicker(
            picker,
            didPickDocumentsAt: [firstURL, secondURL]
        )

        XCTAssertTrue(selectedCopies.isEmpty)
        XCTAssertEqual(cancellationCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondURL.path))
    }

    func test_importedCopyCleanupUnlinksTheSingleSandboxEntry() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try Data([0x01]).write(to: url, options: .atomic)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        WhisperModelImportedCopy(url: url).discard()

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
