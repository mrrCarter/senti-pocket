import CryptoKit
import Darwin
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
        let safeNameCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._")
        guard !identifier.isEmpty,
              identifier.count <= 128,
              identifier.unicodeScalars.allSatisfy(safeNameCharacters.contains),
              !fileName.isEmpty,
              fileName.count <= 128,
              fileName != ".",
              fileName != "..",
              fileName.unicodeScalars.allSatisfy(safeNameCharacters.contains),
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

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                identifier: container.decode(String.self, forKey: .identifier),
                fileName: container.decode(String.self, forKey: .fileName),
                sha256: container.decode(String.self, forKey: .sha256),
                byteCount: container.decode(Int64.self, forKey: .byteCount)
            )
        } catch {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid Whisper model descriptor"
                )
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(identifier, forKey: .identifier)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(byteCount, forKey: .byteCount)
    }

    private init(knownIdentifier: String, fileName: String, sha256: String, byteCount: Int64) {
        identifier = knownIdentifier
        self.fileName = fileName
        self.sha256 = sha256
        self.byteCount = byteCount
    }

    private enum CodingKeys: String, CodingKey {
        case identifier
        case fileName
        case sha256
        case byteCount
    }
}

struct WhisperFileIdentity: Equatable, Sendable {
    let deviceNumber: UInt64
    let fileNumber: UInt64
    let byteCount: Int64

    init(_ status: stat) {
        deviceNumber = UInt64(status.st_dev)
        fileNumber = UInt64(status.st_ino)
        byteCount = Int64(status.st_size)
    }
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
        let verifiedFile = try Self.mapVerificationError {
            try Self.readVerifiedFile(modelURL, against: descriptor, retainBytes: true)
        }
        return VerifiedWhisperModel(
            url: modelURL,
            descriptor: descriptor,
            fileIdentity: verifiedFile.identity,
            modelBytes: verifiedFile.bytes
        )
    }

    static func verifyFile(_ modelURL: URL, against descriptor: WhisperModelDescriptor) throws -> WhisperFileIdentity {
        try mapVerificationError {
            try readVerifiedFile(modelURL, against: descriptor, retainBytes: false).identity
        }
    }

    static func verifyFileDescriptor(
        _ fileDescriptor: Int32,
        against descriptor: WhisperModelDescriptor
    ) throws -> WhisperFileIdentity {
        try mapVerificationError {
            try readVerifiedFileDescriptor(
                fileDescriptor,
                against: descriptor,
                retainBytes: false
            ).identity
        }
    }

    private static func readVerifiedFile(
        _ modelURL: URL,
        against descriptor: WhisperModelDescriptor,
        retainBytes: Bool
    ) throws -> (identity: WhisperFileIdentity, bytes: Data) {
        guard modelURL.isFileURL else { throw VoiceError.modelVerificationFailed }
        let fileDescriptor = modelURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fileDescriptor >= 0 else { throw VoiceError.modelVerificationFailed }
        defer { _ = Darwin.close(fileDescriptor) }
        return try readVerifiedFileDescriptor(
            fileDescriptor,
            against: descriptor,
            retainBytes: retainBytes
        )
    }

    private static func readVerifiedFileDescriptor(
        _ fileDescriptor: Int32,
        against descriptor: WhisperModelDescriptor,
        retainBytes: Bool
    ) throws -> (identity: WhisperFileIdentity, bytes: Data) {
        let before = try descriptorSnapshot(fileDescriptor)
        guard before.identity.byteCount == descriptor.byteCount else {
            throw VoiceError.modelVerificationFailed
        }
        guard Darwin.lseek(fileDescriptor, 0, SEEK_SET) == 0 else {
            throw VoiceError.modelVerificationFailed
        }
        var hasher = SHA256()
        var observedByteCount: Int64 = 0
        var modelBytes = Data()
        if retainBytes {
            modelBytes.reserveCapacity(Int(descriptor.byteCount))
        }
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw VoiceError.modelVerificationFailed }
            if count == 0 { break }
            observedByteCount += Int64(count)
            guard observedByteCount <= descriptor.byteCount else {
                throw VoiceError.modelVerificationFailed
            }
            buffer.withUnsafeBytes { rawBuffer in
                hasher.update(
                    bufferPointer: UnsafeRawBufferPointer(
                        start: rawBuffer.baseAddress,
                        count: count
                    )
                )
            }
            if retainBytes {
                modelBytes.append(contentsOf: buffer.prefix(count))
            }
        }
        try Task.checkCancellation()
        let after = try descriptorSnapshot(fileDescriptor)
        guard before == after, observedByteCount == descriptor.byteCount else {
            throw VoiceError.modelVerificationFailed
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == descriptor.sha256 else {
            throw VoiceError.modelVerificationFailed
        }
        return (after.identity, modelBytes)
    }

    static func fileIdentity(at modelURL: URL) throws -> WhisperFileIdentity {
        try mapVerificationError {
            guard modelURL.isFileURL else { throw VoiceError.modelVerificationFailed }
            var status = stat()
            let result = modelURL.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else { return -1 }
                return Darwin.lstat(path, &status)
            }
            guard result == 0,
                  (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                throw VoiceError.modelVerificationFailed
            }
            return WhisperFileIdentity(status)
        }
    }

    private static func descriptorSnapshot(_ fileDescriptor: Int32) throws -> VerificationSnapshot {
        var status = stat()
        guard Darwin.fstat(fileDescriptor, &status) == 0,
              (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw VoiceError.modelVerificationFailed
        }
        return VerificationSnapshot(status)
    }

    private static func mapVerificationError<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch is CancellationError {
            throw VoiceError.cancelled
        } catch let error as VoiceError {
            throw error
        } catch {
            throw VoiceError.modelVerificationFailed
        }
    }

    private struct VerificationSnapshot: Equatable {
        let identity: WhisperFileIdentity
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(_ status: stat) {
            identity = WhisperFileIdentity(status)
            modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
            changedSeconds = Int64(status.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(status.st_ctimespec.tv_nsec)
        }
    }
}
