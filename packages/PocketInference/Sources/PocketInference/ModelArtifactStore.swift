import CryptoKit
import Foundation

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

public struct VerifiedModelArtifact: Equatable, Sendable {
    public let url: URL
    public let descriptor: ModelDescriptor

    init(url: URL, descriptor: ModelDescriptor) {
        self.url = url
        self.descriptor = descriptor
    }

    func revalidate() throws {
        try ModelArtifactVerifier.verifyFile(at: url, descriptor: descriptor)
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
        try verifyFile(at: url, descriptor: descriptor)
        return VerifiedModelArtifact(url: url, descriptor: descriptor)
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
        try verifyFile(at: temporaryURL, descriptor: descriptor)
        let url = try commitVerifiedFile(at: temporaryURL, descriptor: descriptor)
        return VerifiedModelArtifact(url: url, descriptor: descriptor)
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
        try verifyFile(at: temporaryURL, descriptor: descriptor)
        let url = try commitVerifiedFile(at: temporaryURL, descriptor: descriptor)
        return VerifiedModelArtifact(url: url, descriptor: descriptor)
    }

    public func verifyFile(at url: URL, descriptor: ModelDescriptor) throws {
        try ModelArtifactVerifier.verifyFile(at: url, descriptor: descriptor)
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
    static func verifyFile(at url: URL, descriptor: ModelDescriptor) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              Int64(values.fileSize ?? -1) == descriptor.byteCount else {
            throw ModelArtifactError.byteCountMismatch
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == descriptor.sha256 else {
            throw ModelArtifactError.digestMismatch
        }
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
}
