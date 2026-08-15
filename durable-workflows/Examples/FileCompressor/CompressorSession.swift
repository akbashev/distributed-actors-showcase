import Distributed
import DistributedCluster
import DurableWorkflows
import Foundation
import VirtualActors

@VirtualActor
public distributed actor Compressor {

  public typealias ActorSystem = ClusterSystem

  private var connections: [ClusterSystem.ActorID: Connection] = [:]

  public struct Dependency: Codable, Sendable {
    public init() {}
  }

  public init(actorSystem: ClusterSystem) {
    self.actorSystem = actorSystem
  }

  public static func spawn(on actorSystem: ClusterSystem, dependency: any Sendable & Codable) async throws -> Compressor {
    guard dependency is Dependency else {
      throw VirtualActorError.spawnDependencyTypeMismatch
    }
    return Compressor(actorSystem: actorSystem)
  }

  distributed public func addConnection(_ connection: Connection) {
    connections[connection.id] = connection
  }

  distributed public func removeConnection(id: ClusterSystem.ActorID) {
    connections.removeValue(forKey: id)
  }

  distributed public func fetch(id: WorkflowID, urls: [URL], name: String, connection: Connection) async throws -> String {
    let output = try await actorSystem.workflows.execute(
      type: FileCompressorWorkflow.self,
      // Automatic retry: a transient download/zip failure re-runs the
      // workflow after a backoff instead of failing the session. Completed
      // activities replay from the journal, so a retry only re-dispatches
      // what never finished.
      options: .init(
        id: id,
        retryPolicy: RetryPolicy(initialInterval: .seconds(2), maximumAttempts: 3)
      ),
      input: FileCompressorWorkflow.Input(urls: urls, archiveName: name, connection: connection)
    )
    await broadcast(.archieved(URL(fileURLWithPath: output.archivePath)))
    return output.archivePath
  }

  distributed public func notify(_ message: Connection.Message) async throws {
    await broadcast(message)
  }

  private func broadcast(_ message: Connection.Message) async {
    for connection in connections.values {
      try? await connection.notify(message)
    }
  }
}

// MARK: - Connection (ephemeral, like Connection in TravelBooking)

public distributed actor Connection {

  public typealias ActorSystem = ClusterSystem

  public enum Message: Sendable, Codable {
    case started
    case download(file: URL, fileIndex: Int, fraction: Double)
    case archieved(URL)
  }

  private let onNotify: @Sendable (Message, [Int: Double]) async throws -> Void
  private var downloadFractions: [Int: Double] = [:]

  public init(
    actorSystem: ClusterSystem,
    onNotify: @escaping @Sendable (Message, [Int: Double]) async throws -> Void
  ) {
    self.actorSystem = actorSystem
    self.onNotify = onNotify
  }

  distributed public func notify(_ message: Message) async throws {
    if case .download(_, let index, let fraction) = message {
      downloadFractions[index] = fraction
    }
    try await onNotify(message, downloadFractions)
  }
}
