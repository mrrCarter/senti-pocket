import CryptoKit
import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct ModelDescriptor: Codable, Equatable, Sendable {
    public let identifier: String
    public let fileName: String
    public let sha256: String
    public let byteCount: Int64

    public init(identifier: String, fileName: String, sha256: String, byteCount: Int64) throws {
        let safeIdentifier = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))
        guard !identifier.isEmpty,
              identifier.count <= 128,
              identifier.unicodeScalars.allSatisfy(safeIdentifier.contains) else {
            throw ModelArtifactError.invalidDescriptor("identifier")
        }
        guard fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              URL(fileURLWithPath: fileName).pathExtension == "litertlm" else {
            throw ModelArtifactError.invalidDescriptor("fileName")
        }
        guard sha256.count == 64,
              sha256.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else {
            throw ModelArtifactError.invalidDescriptor("sha256")
        }
        guard (1...17_179_869_184).contains(byteCount) else {
            throw ModelArtifactError.invalidDescriptor("byteCount")
        }

        self.identifier = identifier
        self.fileName = fileName
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

struct ModelFileIdentity: Equatable, Sendable {
    let deviceNumber: UInt64
    let fileNumber: UInt64
    let byteCount: Int64
}

public struct VerifiedModelArtifact: Equatable, Sendable {
    public let url: URL
    public let descriptor: ModelDescriptor
    private let fileIdentity: ModelFileIdentity

    init(url: URL, descriptor: ModelDescriptor, fileIdentity: ModelFileIdentity) {
        self.url = url
        self.descriptor = descriptor
        self.fileIdentity = fileIdentity
    }

    func revalidate() throws {
        let currentIdentity = try ModelArtifactVerifier.verifyFile(at: url, descriptor: descriptor)
        guard currentIdentity == fileIdentity else {
            throw ModelArtifactError.fileChangedAfterVerification
        }
    }

    func makeRuntimeSnapshot(in parentDirectory: URL) throws -> RuntimeModelSnapshot {
        try ModelArtifactVerifier.makeRuntimeSnapshot(
            from: url,
            descriptor: descriptor,
            in: parentDirectory
        )
    }
}

final class RuntimeModelSnapshot: @unchecked Sendable {
    let url: URL
    private let directory: URL
    private let fileManager: FileManager

    init(url: URL, directory: URL, fileManager: FileManager) {
        self.url = url
        self.directory = directory
        self.fileManager = fileManager
    }

    deinit {
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? fileManager.removeItem(at: directory)
    }
}

public actor ModelArtifactStore {
    private let rootDirectory: URL
    private let fileManager: FileManager
    private let downloadSession: URLSession
    private let allowedDownloadHosts: Set<String>

    public init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        downloadSession: URLSession? = nil,
        allowedDownloadHosts: Set<String> = []
    ) {
        self.rootDirectory = rootDirectory
        self.fileManager = fileManager
        self.downloadSession = downloadSession ?? Self.makeDownloadSession()
        self.allowedDownloadHosts = Set(allowedDownloadHosts.map { $0.lowercased() })
    }

    public func installedURL(for descriptor: ModelDescriptor) -> URL {
        rootDirectory.appendingPathComponent(descriptor.fileName, isDirectory: false)
    }

    public func verifyInstalledModel(_ descriptor: ModelDescriptor) throws -> VerifiedModelArtifact {
        let url = installedURL(for: descriptor)
        let identity = try ModelArtifactVerifier.verifyFile(at: url, descriptor: descriptor)
        return VerifiedModelArtifact(url: url, descriptor: descriptor, fileIdentity: identity)
    }

    public func installLocalFile(
        at sourceURL: URL,
        descriptor: ModelDescriptor
    ) throws -> VerifiedModelArtifact {
        guard rootDirectory.isFileURL, sourceURL.isFileURL else {
            throw ModelArtifactError.invalidFileURL
        }
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let temporaryURL = rootDirectory.appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try fileManager.copyItem(at: sourceURL, to: temporaryURL)
        _ = try ModelArtifactVerifier.verifyFile(at: temporaryURL, descriptor: descriptor)
        let url = try commitVerifiedFile(at: temporaryURL, descriptor: descriptor)
        let identity = try ModelArtifactVerifier.verifyFile(at: url, descriptor: descriptor)
        return VerifiedModelArtifact(url: url, descriptor: descriptor, fileIdentity: identity)
    }

    public func downloadAndInstall(
        from sourceURL: URL,
        descriptor: ModelDescriptor
    ) async throws -> VerifiedModelArtifact {
        guard rootDirectory.isFileURL else {
            throw ModelArtifactError.invalidFileURL
        }
        guard sourceURL.scheme?.lowercased() == "https",
              sourceURL.user == nil,
              sourceURL.password == nil,
              let sourceHost = sourceURL.host?.lowercased(),
              allowedDownloadHosts.contains(sourceHost) else {
            throw ModelArtifactError.insecureTransport
        }

        var request = URLRequest(
            url: sourceURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: 300
        )
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let delegate = BoundedModelDownloadDelegate(expectedByteCount: descriptor.byteCount)
        let downloadedURL: URL
        let response: URLResponse
        do {
            (downloadedURL, response) = try await downloadSession.download(
                for: request,
                delegate: delegate
            )
        } catch {
            if delegate.exceededExpectedByteCount {
                throw ModelArtifactError.byteCountMismatch
            }
            throw error
        }
        defer { try? fileManager.removeItem(at: downloadedURL) }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https",
              http.url?.host?.lowercased() == sourceHost else {
            throw ModelArtifactError.downloadRejected
        }
        if http.expectedContentLength != NSURLSessionTransferSizeUnknown,
           http.expectedContentLength != descriptor.byteCount {
            throw ModelArtifactError.byteCountMismatch
        }

        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let temporaryURL = rootDirectory.appendingPathComponent(".\(UUID().uuidString).partial")
        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        try fileManager.moveItem(at: downloadedURL, to: temporaryURL)
        _ = try ModelArtifactVerifier.verifyFile(at: temporaryURL, descriptor: descriptor)
        let url = try commitVerifiedFile(at: temporaryURL, descriptor: descriptor)
        let identity = try ModelArtifactVerifier.verifyFile(at: url, descriptor: descriptor)
        return VerifiedModelArtifact(url: url, descriptor: descriptor, fileIdentity: identity)
    }

    public func verifyFile(at url: URL, descriptor: ModelDescriptor) throws {
        _ = try ModelArtifactVerifier.verifyFile(at: url, descriptor: descriptor)
    }

    private func commitVerifiedFile(at temporaryURL: URL, descriptor: ModelDescriptor) throws -> URL {
        let destination = installedURL(for: descriptor)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableTemporaryURL = temporaryURL
        try mutableTemporaryURL.setResourceValues(resourceValues)

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: destination)
        }
        return destination
    }

    private static func makeDownloadSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 1_800
        return URLSession(configuration: configuration)
    }
}

private enum ModelArtifactVerifier {
    static func verifyFile(at url: URL, descriptor: ModelDescriptor) throws -> ModelFileIdentity {
        let before = try fileIdentity(at: url)
        guard before.byteCount == descriptor.byteCount else {
            throw ModelArtifactError.byteCountMismatch
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var observedByteCount: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            observedByteCount += Int64(chunk.count)
            hasher.update(data: chunk)
        }
        let after = try fileIdentity(at: url)
        guard before == after, observedByteCount == descriptor.byteCount else {
            throw ModelArtifactError.fileChangedDuringVerification
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == descriptor.sha256 else {
            throw ModelArtifactError.digestMismatch
        }
        return after
    }

    static func makeRuntimeSnapshot(
        from sourceURL: URL,
        descriptor: ModelDescriptor,
        in parentDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> RuntimeModelSnapshot {
        guard sourceURL.isFileURL, parentDirectory.isFileURL else {
            throw ModelArtifactError.invalidFileURL
        }

        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let directory = parentDirectory.appendingPathComponent(
            ".aidenid-model-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var shouldRemoveDirectory = true
        defer {
            if shouldRemoveDirectory {
                try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
                try? fileManager.removeItem(at: directory)
            }
        }

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(resourceValues)

        let snapshotURL = directory.appendingPathComponent(descriptor.fileName, isDirectory: false)
        if cloneFileIfAvailable(from: sourceURL, to: snapshotURL) {
            _ = try verifyFile(at: snapshotURL, descriptor: descriptor)
        } else {
            try copyVerifiedBytes(from: sourceURL, to: snapshotURL, descriptor: descriptor, fileManager: fileManager)
        }

        try fileManager.setAttributes([.posixPermissions: 0o400], ofItemAtPath: snapshotURL.path)
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        shouldRemoveDirectory = false
        return RuntimeModelSnapshot(url: snapshotURL, directory: directory, fileManager: fileManager)
    }

    private static func cloneFileIfAvailable(from sourceURL: URL, to destinationURL: URL) -> Bool {
        #if canImport(Darwin)
        return sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return false }
                return clonefile(sourcePath, destinationPath, 0) == 0
            }
        }
        #else
        return false
        #endif
    }

    private static func copyVerifiedBytes(
        from sourceURL: URL,
        to snapshotURL: URL,
        descriptor: ModelDescriptor,
        fileManager: FileManager
    ) throws {
        guard fileManager.createFile(
            atPath: snapshotURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw ModelArtifactError.runtimeSnapshotFailed
        }

        let source = try FileHandle(forReadingFrom: sourceURL)
        let destination = try FileHandle(forWritingTo: snapshotURL)
        defer {
            try? source.close()
            try? destination.close()
        }

        var hasher = SHA256()
        var observedByteCount: Int64 = 0
        while true {
            let chunk = try source.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            observedByteCount += Int64(chunk.count)
            guard observedByteCount <= descriptor.byteCount else {
                throw ModelArtifactError.byteCountMismatch
            }
            hasher.update(data: chunk)
            try destination.write(contentsOf: chunk)
        }
        try destination.synchronize()

        guard observedByteCount == descriptor.byteCount else {
            throw ModelArtifactError.byteCountMismatch
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == descriptor.sha256 else {
            throw ModelArtifactError.digestMismatch
        }
    }

    private static func fileIdentity(at url: URL) throws -> ModelFileIdentity {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ModelArtifactError.invalidFileURL
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attributes[.systemNumber] as? NSNumber,
              let file = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber else {
            throw ModelArtifactError.invalidFileURL
        }
        return ModelFileIdentity(
            deviceNumber: device.uint64Value,
            fileNumber: file.uint64Value,
            byteCount: size.int64Value
        )
    }
}

private final class BoundedModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedByteCount: Int64
    private let lock = NSLock()
    private var exceeded = false

    init(expectedByteCount: Int64) {
        self.expectedByteCount = expectedByteCount
    }

    var exceededExpectedByteCount: Bool {
        lock.withLock { exceeded }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten > expectedByteCount else { return }
        lock.withLock { exceeded = true }
        downloadTask.cancel()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}

public enum ModelArtifactError: Error, Equatable, Sendable {
    case invalidDescriptor(String)
    case insecureTransport
    case downloadRejected
    case invalidFileURL
    case byteCountMismatch
    case digestMismatch
    case fileChangedDuringVerification
    case fileChangedAfterVerification
    case runtimeSnapshotFailed
}
