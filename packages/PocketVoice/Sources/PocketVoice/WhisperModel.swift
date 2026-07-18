import CryptoKit
import Foundation

public struct WhisperModelDescriptor: Codable, Equatable, Sendable {
    public static let baseEnglish = WhisperModelDescriptor(
        knownIdentifier: "whisper-base.en",
        fileName: "ggml-base.en.bin",
        sha256: "a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002",
        byteCount: 147_964_211
    )

    public let identifier: String
    public let fileName: String
    public let sha256: String
    public let byteCount: Int64

    public init(identifier: String, fileName: String, sha256: String, byteCount: Int64) throws {
        let allowedIdentifier = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        guard !identifier.isEmpty,
              identifier.count <= 128,
              identifier.unicodeScalars.allSatisfy(allowedIdentifier.contains),
              fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              fileName.hasSuffix(".bin"),
              sha256.count == 64,
              sha256.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }),
              (1...2_147_483_648).contains(byteCount) else {
            throw VoiceError.modelVerificationFailed
        }
        self.identifier = identifier
        self.fileName = fileName
        self.sha256 = sha256
        self.byteCount = byteCount
    }

    private init(knownIdentifier: String, fileName: String, sha256: String, byteCount: Int64) {
        identifier = knownIdentifier
        self.fileName = fileName
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

public struct WhisperModelVerifier: Sendable {
    public init() {}

    public func verify(_ modelURL: URL, against descriptor: WhisperModelDescriptor) throws -> URL {
        guard modelURL.isFileURL,
              modelURL.lastPathComponent == descriptor.fileName else {
            throw VoiceError.modelVerificationFailed
        }
        let values = try modelURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              Int64(values.fileSize ?? -1) == descriptor.byteCount else {
            throw VoiceError.modelVerificationFailed
        }

        let handle = try FileHandle(forReadingFrom: modelURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == descriptor.sha256 else {
            throw VoiceError.modelVerificationFailed
        }
        return modelURL
    }
}
