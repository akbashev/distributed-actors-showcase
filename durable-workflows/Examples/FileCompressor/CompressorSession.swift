import Distributed
import DistributedCluster
import DurableWorkflows
import EventSourcing
import Foundation
import VirtualActors

@EventSourced
@VirtualActor
public distributed actor Compressor {

  public typealias ActorSystem = ClusterSystem

  private let sessionId: String
  private var connections: [ClusterSystem.ActorID: Connection] = [:]

  public struct State: Codable, Sendable {
    public var files: [String: File] = [:]
  }

  public var state = State()

  public struct Dependency: Codable, Sendable {
    public let sessionId: String
    public init(sessionId: String) { self.sessionId = sessionId }
  }

  public init(actorSystem: ClusterSystem, sessionId: String) {
    self.actorSystem = actorSystem
    self.sessionId = sessionId
  }

  public struct File: Sendable, Codable {
    public enum Status: Sendable, Codable {
      case started
      case loading(index: Int, progress: Double)
      case finished
    }
    public let name: String
    public let status: File.Status
  }

  public enum Event: Sendable, Codable {
    case fileStarted(name: String)
    case fileFinished(name: String)
  }

  public static func spawn(on actorSystem: ClusterSystem, dependency: any Sendable & Codable) async throws -> Compressor {
    guard let dep = dependency as? Dependency else {
      throw VirtualActorError.spawnDependencyTypeMismatch
    }
    return Compressor(actorSystem: actorSystem, sessionId: dep.sessionId)
  }

  distributed public func addConnection(_ connection: Connection) {
    connections[connection.id] = connection
  }

  distributed public func removeConnection(id: ClusterSystem.ActorID) {
    connections.removeValue(forKey: id)
  }

  distributed public func fetch(id: String, urls: [URL], name: String, connection: Connection) async throws -> String {
    let output = try await actorSystem.workflows.execute(
      type: FileCompressorWorkflow.self,
      options: .init(id: id),
      input: FileCompressorWorkflow.Input(urls: urls, archiveName: name, connection: connection)
    )
    try? await broadcast(.archieved(URL(fileURLWithPath: output.archivePath)))
    return output.archivePath
  }

  distributed public func notify(_ message: Connection.Message) async throws {
    try await broadcast(message)
  }

  private func broadcast(_ message: Connection.Message) async {
    for connection in connections.values {
      try? await connection.notify(message)
    }
  }

  public func handleEvent(_ event: Event) {
    switch event {
    case .fileStarted(let name):
      self.state.files[name] = File(name: name, status: .started)
    case .fileFinished(let name):
      self.state.files[name] = File(name: name, status: .finished)
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
