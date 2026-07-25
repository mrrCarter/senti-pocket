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

struct WhisperFileIdentity: Equatable, Sendable {
    let deviceNumber: UInt64
    let fileNumber: UInt64
    let byteCount: Int64
}

public struct VerifiedWhisperModel: Equatable, Sendable {
    public let url: URL
    public let descriptor: WhisperModelDescriptor
    private let fileIdentity: WhisperFileIdentity
    let modelBytes: Data

    init(
        url: URL,
        descriptor: WhisperModelDescriptor,
        fileIdentity: WhisperFileIdentity,
        modelBytes: Data
    ) {
        self.url = url
        self.descriptor = descriptor
        self.fileIdentity = fileIdentity
        self.modelBytes = modelBytes
    }

    func revalidate() throws {
        let current = try WhisperModelVerifier.verifyFile(url, against: descriptor)
        guard current == fileIdentity else { throw VoiceError.modelVerificationFailed }
    }
}

public struct WhisperModelVerifier: Sendable {
    public init() {}

    public func verify(_ modelURL: URL, against descriptor: WhisperModelDescriptor) throws -> VerifiedWhisperModel {
        guard modelURL.isFileURL,
              modelURL.lastPathComponent == descriptor.fileName else {
            throw VoiceError.modelVerificationFailed
        }
        let verifiedFile = try Self.readVerifiedFile(modelURL, against: descriptor, retainBytes: true)
        return VerifiedWhisperModel(
            url: modelURL,
            descriptor: descriptor,
            fileIdentity: verifiedFile.identity,
            modelBytes: verifiedFile.bytes
        )
    }

    static func verifyFile(_ modelURL: URL, against descriptor: WhisperModelDescriptor) throws -> WhisperFileIdentity {
        try readVerifiedFile(modelURL, against: descriptor, retainBytes: false).identity
    }

    private static func readVerifiedFile(
        _ modelURL: URL,
        against descriptor: WhisperModelDescriptor,
        retainBytes: Bool
    ) throws -> (identity: WhisperFileIdentity, bytes: Data) {
        let before = try fileIdentity(at: modelURL)
        guard before.byteCount == descriptor.byteCount else { throw VoiceError.modelVerificationFailed }

        let handle = try FileHandle(forReadingFrom: modelURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        var observedByteCount: Int64 = 0
        var modelBytes = Data()
        if retainBytes {
            modelBytes.reserveCapacity(Int(descriptor.byteCount))
        }
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            observedByteCount += Int64(chunk.count)
            guard observedByteCount <= descriptor.byteCount else {
                throw VoiceError.modelVerificationFailed
            }
            hasher.update(data: chunk)
            if retainBytes { modelBytes.append(chunk) }
        }
        let after = try fileIdentity(at: modelURL)
        guard before == after, observedByteCount == descriptor.byteCount else {
            throw VoiceError.modelVerificationFailed
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == descriptor.sha256 else {
            throw VoiceError.modelVerificationFailed
        }
        return (after, modelBytes)
    }

    private static func fileIdentity(at modelURL: URL) throws -> WhisperFileIdentity {
        let values = try modelURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw VoiceError.modelVerificationFailed
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: modelURL.path)
        guard let device = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber else {
            throw VoiceError.modelVerificationFailed
        }
        return WhisperFileIdentity(
            deviceNumber: device.uint64Value,
            fileNumber: file.uint64Value,
            byteCount: size.int64Value
        )
    }
}
