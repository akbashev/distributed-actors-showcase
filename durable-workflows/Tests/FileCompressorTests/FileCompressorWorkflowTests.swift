import DistributedCluster
import DurableWorkflows
import FileCompressor
import Foundation
import Synchronization
import Testing

/// Records every message pushed to a `Connection` during a workflow run.
final class MessageRecorder: Sendable {
  private let _messages = Mutex<[Connection.Message]>([])

  var messages: [Connection.Message] {
    self._messages.withLock { $0 }
  }

  @Sendable
  func record(_ message: Connection.Message, _ fractions: [Int: Double]) async throws {
    self._messages.withLock { $0.append(message) }
  }
}

/// Runs a process to completion and returns its stdout.
func runProcess(_ executable: String, _ arguments: [String]) throws -> String {
  let process = Process()
  let pipe = Pipe()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.standardOutput = pipe
  try process.run()
  process.waitUntilExit()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  return String(data: data, encoding: .utf8) ?? ""
}

/// Spawns the session's `Compressor` and registers a recorder-backed
/// `Connection` with it — the demo's shape: the workflow input carries the
/// stable virtual actor, and progress broadcasts reach its connections.
func makeRecordingCompressor(
  on system: ClusterSystem,
  id: String,
  recorder: MessageRecorder
) async throws -> Compressor {
  let compressor: Compressor = try await system.virtualActors.getActor(
    identifiedBy: .init(rawValue: id),
    dependency: Compressor.Dependency()
  )
  let connection = Connection(actorSystem: system, onNotify: recorder.record)
  try await compressor.addConnection(connection)
  return compressor
}

/// End-to-end `FileCompressorWorkflow` behavior over a real single-node
/// cluster, with downloads served by an in-process Hummingbird fixture —
/// no external network.
@Suite(.timeLimit(.minutes(2)))
struct FileCompressorWorkflowTests {

  @Test
  func compressTwoFilesProducesArchiveAndCleansUp() async throws {
    let server = FixtureFileServer(port: 18081)
    try await server.start()

    let (system, node, worker) = try await makeCompressorWorkflowSystem(
      name: "compressor-happy",
      port: 4610,
      store: InMemoryEventStore()
    )
    let options = WorkflowOptions(id: "fc-happy")
    defer { try? FileManager.default.removeItem(at: compressorStorageDir(workflowID: options.id)) }

    let recorder = MessageRecorder()
    let compressor = try await makeRecordingCompressor(on: system, id: "compressor-fc-happy", recorder: recorder)
    let output = try await system.workflows.execute(
      type: FileCompressorWorkflow.self,
      options: options,
      input: .init(
        urls: [server.alphaURL, server.betaURL],
        archiveName: "fc-happy-archive",
        compressor: compressor
      )
    )

    // The archive exists and lists both downloaded files (zip -j: basenames
    // only, and FetchAndStore prefixes each file with its URL index).
    #expect(FileManager.default.fileExists(atPath: output.archivePath))
    let listing = try runProcess("/usr/bin/unzip", ["-l", output.archivePath])
    #expect(listing.contains("0_alpha.txt"))
    #expect(listing.contains("1_beta.txt"))

    // DeleteFiles removed the downloaded sources, leaving only the archive.
    let dir = try compressorStorageDir(workflowID: options.id)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("0_alpha.txt").path))
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("1_beta.txt").path))

    #expect(server.hitCount(for: "/alpha.txt") == 1)
    #expect(server.hitCount(for: "/beta.txt") == 1)

    _ = node
    _ = worker
  }

  @Test
  func downloadProgressNotificationsCoverBothFiles() async throws {
    let server = FixtureFileServer(port: 18082)
    try await server.start()

    let (system, node, worker) = try await makeCompressorWorkflowSystem(
      name: "compressor-progress",
      port: 4611,
      store: InMemoryEventStore()
    )
    let options = WorkflowOptions(id: "fc-progress")
    defer { try? FileManager.default.removeItem(at: compressorStorageDir(workflowID: options.id)) }

    let recorder = MessageRecorder()
    let compressor = try await makeRecordingCompressor(on: system, id: "compressor-fc-progress", recorder: recorder)
    _ = try await system.workflows.execute(
      type: FileCompressorWorkflow.self,
      options: options,
      input: .init(
        urls: [server.alphaURL, server.betaURL],
        archiveName: "fc-progress-archive",
        compressor: compressor
      )
    )

    let downloads = recorder.messages.compactMap { message -> (index: Int, fraction: Double)? in
      guard case .download(_, let index, let fraction) = message else { return nil }
      return (index, fraction)
    }
    #expect(downloads.contains { $0.index == 0 })
    #expect(downloads.contains { $0.index == 1 })
    for download in downloads {
      #expect(download.fraction >= 0 && download.fraction <= 1)
    }
    // Every file reports completion (fraction 1.0) at the end of its fetch.
    #expect(downloads.contains { $0.index == 0 && $0.fraction == 1.0 })
    #expect(downloads.contains { $0.index == 1 && $0.fraction == 1.0 })

    _ = node
    _ = worker
  }

  @Test
  func failedFetchRetriesAutomaticallyWithoutRefetchingSucceededDownload() async throws {
    let server = FixtureFileServer(port: 18083)
    try await server.start()
    server.flakyFailuresRemaining = 1

    let (system, node, worker) = try await makeCompressorWorkflowSystem(
      name: "compressor-retry",
      port: 4612,
      store: InMemoryEventStore()
    )
    let options = WorkflowOptions(
      id: "fc-retry",
      retryPolicy: RetryPolicy(initialInterval: .milliseconds(50), maximumAttempts: 2)
    )
    defer { try? FileManager.default.removeItem(at: compressorStorageDir(workflowID: options.id)) }

    let recorder = MessageRecorder()
    let compressor = try await makeRecordingCompressor(on: system, id: "compressor-fc-retry", recorder: recorder)
    let input = FileCompressorWorkflow.Input(
      urls: [server.alphaURL, server.flakyURL],
      archiveName: "fc-retry-archive",
      compressor: compressor
    )

    // The flaky URL answers 500 once; the retry policy re-runs the workflow
    // automatically and the caller only sees the final success.
    let output = try await system.workflows.execute(
      type: FileCompressorWorkflow.self,
      options: options,
      input: input
    )
    #expect(FileManager.default.fileExists(atPath: output.archivePath))

    let info = try await system.workflows.getStatus(type: FileCompressorWorkflow.self, options: options)
    guard case .completed = info.status else {
      Issue.record("expected completed, got \(info.status)")
      return
    }

    // The succeeded download was served from the journal, not re-fetched;
    // the flaky one was re-dispatched exactly once.
    #expect(server.hitCount(for: "/alpha.txt") == 1)
    #expect(server.hitCount(for: "/flaky.txt") == 2)

    _ = node
    _ = worker
  }
}
