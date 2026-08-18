import Distributed
import DistributedCluster
import DurableWorkflows
import Foundation
import Synchronization

@ActivityContainer
public struct FileCompressorActivities {
  public struct FetchRequest: Codable, Sendable {
    public let url: URL
    public let index: Int
    public let compressor: Compressor

    public init(url: URL, index: Int, compressor: Compressor) {
      self.url = url
      self.index = index
      self.compressor = compressor
    }
  }

  public struct ArchiveRequest: Codable, Sendable {
    public let files: [String]
    public let archiveName: String

    public init(files: [String], archiveName: String) {
      self.files = files
      self.archiveName = archiveName
    }
  }

  @Activity
  public func fetchAndStore(input: FetchRequest, context: ActivityContext) async throws -> String {
    var request = URLRequest(url: input.url)
    request.timeoutInterval = 60
    // Identify ourselves: some servers RST connections carrying URLSession's
    // default CFNetwork user agent (verified against Hetzner's speedtest
    // host); any explicit UA is served fine.
    request.setValue("DurableWorkflowsDemo/1.0", forHTTPHeaderField: "User-Agent")
    var result: (url: URL, response: URLResponse)? = nil
    for try await status in try await URLSession.shared.download(for: request) {
      switch status {
      case .downloading(let progress):
        try? await input.compressor.notify(.download(file: input.url, fileIndex: input.index, fraction: progress))
      case let .finished(url, response):
        result = (url, response)
      }
    }
    // A cancelled download ends the stream WITHOUT a result — report
    // cancellation as cancellation, never as a fetch failure.
    try Task.checkCancellation()
    guard let result else {
      throw ApplicationError.typed(
        message: "Download of \(input.url) ended without a response",
        type: "FetchError",
        isNonRetryable: false
      )
    }
    guard
      let httpResponse = result.response as? HTTPURLResponse,
      httpResponse.statusCode == 200
    else {
      let code = (result.response as? HTTPURLResponse)?.statusCode.description ?? "no HTTP response"
      throw ApplicationError.typed(
        message: "Failed to fetch \(input.url): HTTP \(code)",
        type: "FetchError",
        isNonRetryable: false
      )
    }

    // Cap individual downloads; expectedContentLength is -1 for chunked
    // responses, so measure the actual file.
    let maxFileBytes = 500 * 1024 * 1024
    let size = (try? FileManager.default.attributesOfItem(atPath: result.url.path)[.size] as? Int) ?? 0
    guard size <= maxFileBytes else {
      throw ApplicationError.typed(
        message: "File too large (\(size) bytes, max \(maxFileBytes))",
        type: "FetchError",
        isNonRetryable: true
      )
    }

    let tmpDir = try Self.storageDir(workflowID: context.workflowID)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let basename = input.url.lastPathComponent.isEmpty ? UUID().uuidString : input.url.lastPathComponent
    let dest = tmpDir.appendingPathComponent("\(input.index)_\(basename)")
    // Crash between the move and journaling the result replays into an
    // already-moved file: replace, don't fail.
    try? FileManager.default.removeItem(at: dest)
    try FileManager.default.moveItem(at: result.url, to: dest)
    return dest.path
  }

  @Activity
  public func createArchive(input: ArchiveRequest, context: ActivityContext) async throws -> String {
    // zip exit 12 on an empty file list is permanent — fail fast, never retry.
    guard !input.files.isEmpty else {
      throw ApplicationError.typed(
        message: "Nothing to archive",
        type: "ArchiveError",
        isNonRetryable: true
      )
    }
    let tmpDir = try Self.storageDir(workflowID: context.workflowID)
    let archivePath = tmpDir.appendingPathComponent("\(input.archiveName).zip").path
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.arguments = ["-j", archivePath] + input.files
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw ApplicationError.typed(
        message: "zip failed with status \(process.terminationStatus)",
        type: "ArchiveError",
        isNonRetryable: false
      )
    }
    return archivePath
  }

  @Activity
  public func deleteFiles(input: [String], context: ActivityContext) async throws {
    for path in input {
      try? FileManager.default.removeItem(atPath: path)
    }
  }

  /// Stable per-workflow storage — Application Support, NOT the system temp
  /// directory: a completed workflow's journal must not outlive the archive
  /// it points to (tmp is purged on reboot).
  private static func storageDir(workflowID: WorkflowID) throws -> URL {
    try Self.applicationSupportDir()
      .appendingPathComponent("durable-workflows-demo/compressor/\(workflowID.rawValue)")
  }

  /// `urls(for:in:)` can legally return an empty array — never index `[0]`,
  /// and never silently fall back to a location the caller didn't choose:
  /// fail instead.
  public static func applicationSupportDir() throws -> URL {
    guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else {
      throw ApplicationError.typed(
        message: "Application Support directory unavailable",
        type: "StorageError",
        isNonRetryable: true
      )
    }
    return dir
  }
}

extension URLSession {

  fileprivate enum DownloadStatus {
    case downloading(Double)
    case finished(URL, URLResponse)
  }

  fileprivate final class ProgressObserver: NSObject, URLSessionTaskDelegate, Sendable {

    let observation: Mutex<NSKeyValueObservation?> = .init(.none)
    let changeHandler: @Sendable (sending Progress) -> Void

    init(changeHandler: @Sendable @escaping (sending Progress) -> Void) {
      self.changeHandler = changeHandler
    }

    func urlSession(_ connection: URLSession, didCreateTask task: URLSessionTask) {
      self.observation.withLock {
        $0 = task.progress.observe(\.fractionCompleted) { progress, change in
          self.changeHandler(progress)
        }
      }
    }

    deinit {
      self.observation.withLock {
        $0?.invalidate()
        $0 = nil
      }
    }
  }

  fileprivate func download(for request: URLRequest) async throws -> AsyncThrowingStream<DownloadStatus, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        let delegate = ProgressObserver {
          continuation.yield(.downloading($0.fractionCompleted))
        }
        do {
          let (url, response) = try await URLSession.shared.download(
            for: request,
            delegate: delegate
          )
          continuation.yield(.finished(url, response))
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }
}
