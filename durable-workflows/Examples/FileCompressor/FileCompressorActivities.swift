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
    public let connection: Connection

    public init(url: URL, index: Int, connection: Connection) {
      self.url = url
      self.index = index
      self.connection = connection
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
    let request = URLRequest(url: input.url)
    var result: (url: URL, response: URLResponse)? = nil
    for try await status in try await URLSession.shared.download(for: request) {
      switch status {
      case .downloading(let progress):
        try? await input.connection.notify(.download(file: input.url, fileIndex: input.index, fraction: progress))
      case let .finished(url, response):
        result = (url, response)
      }
    }
    guard
      let result,
      let httpResponse = result.response as? HTTPURLResponse,
      httpResponse.statusCode == 200
    else {
      throw ApplicationError.typed(
        message: "Failed to fetch \(input.url)",
        type: "FetchError",
        isNonRetryable: false
      )
    }

    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("durable-compressor/\(context.workflowID)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    let basename = input.url.lastPathComponent.isEmpty ? UUID().uuidString : input.url.lastPathComponent
    let dest = tmpDir.appendingPathComponent("\(input.index)_\(basename)")
    try FileManager.default.moveItem(at: result.url, to: dest)
    return dest.path
  }

  @Activity
  public func createArchive(input: ArchiveRequest, context: ActivityContext) async throws -> String {
    let tmpDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("durable-compressor/\(context.workflowID)")
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
