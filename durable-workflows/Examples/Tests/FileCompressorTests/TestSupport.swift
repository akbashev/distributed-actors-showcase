import DistributedCluster
import DurableWorkflows
import EventSourcing
import FileCompressor
import Foundation
import Synchronization
import VirtualActors

/// Journal store for tests: keeps events in memory, idempotent per
/// `(id, sequenceNumber)` as `EventStore` requires. Mirrors the parent
/// package's test harness.
final class InMemoryEventStore: EventStore, Sendable {
  struct Conflict: Error {}

  private let storage = Mutex<[String: [(sequenceNumber: Int64, data: Data)]]>([:])

  func persistEvent<Event: Codable & Sendable>(
    _ event: Event,
    id: String,
    sequenceNumber: Int64
  ) async throws {
    let data = try JSONEncoder().encode(event)
    try self.storage.withLock { store in
      var log = store[id] ?? []
      if let existing = log.first(where: { $0.sequenceNumber == sequenceNumber }) {
        guard existing.data == data else { throw Conflict() }
        return
      }
      log.append((sequenceNumber, data))
      log.sort { $0.sequenceNumber < $1.sequenceNumber }
      store[id] = log
    }
  }

  func eventsFor<Event: Codable & Sendable>(
    id: String,
    fromSequenceNumber: Int64
  ) async throws -> [Event] {
    let log = self.storage.withLock { $0[id] ?? [] }
    return
      try log
      .filter { $0.sequenceNumber >= fromSequenceNumber }
      .map { try JSONDecoder().decode(Event.self, from: $0.data) }
  }
}

/// Boots a single-node cluster with the full plugin stack and a
/// `FileCompressorWorkflow` worker. The returned node and worker must stay
/// bound for the system's lifetime — nothing else retains them.
func makeCompressorWorkflowSystem(
  name: String,
  port: Int,
  store: InMemoryEventStore
) async throws -> (ClusterSystem, VirtualNode, DurableActivityDispatchWorker<FileCompressorWorkflow>) {
  let system = await ClusterSystem(name) {
    $0.bindPort = port
    // For singleton plugin to work we need to choose a leader by having 1 member
    $0.autoLeaderElection = .lowestReachable(minNumberOfMembers: 1)
    $0.plugins.install(plugin: ClusterSingletonPlugin())
    $0.plugins.install(plugin: ClusterVirtualActorsPlugin(replicationFactor: 10))
    $0.plugins.install(plugin: ClusterJournalPlugin { _ in store })
    $0.plugins.install(plugin: DurableWorkflowsPlugin())
  }
  let node = await VirtualNode(actorSystem: system)
  let worker = await DurableActivityDispatchWorker<FileCompressorWorkflow>(actorSystem: system)
  system.cluster.join(endpoint: system.cluster.endpoint)
  try await system.cluster.joined(within: .seconds(5))
  return (system, node, worker)
}

/// Polls until `condition` holds or the attempts run out.
func eventually(
  attempts: Int = 100,
  interval: Duration = .milliseconds(50),
  _ condition: () async throws -> Bool
) async throws {
  for _ in 0..<attempts {
    if try await condition() { return }
    try await Task.sleep(for: interval)
  }
  struct Timeout: Error {}
  throw Timeout()
}

/// Where `FileCompressorActivities` stores downloads and the archive for a
/// given workflow ID.
func compressorStorageDir(workflowID: WorkflowID) throws -> URL {
  try FileCompressorActivities.applicationSupportDir()
    .appendingPathComponent("durable-workflows-demo/compressor/\(workflowID.rawValue)")
}
