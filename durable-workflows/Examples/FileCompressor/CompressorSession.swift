import Distributed
import DistributedCluster
import DurableWorkflows
import EventSourcing
import Foundation
import VirtualActors

@EventSourced
public distributed actor Compressor: VirtualActor {

  public typealias ActorSystem = ClusterSystem

  private let sessionId: String
  private var files: [String: File] = [:]

  public struct Dependency: Codable, Sendable {
    public let sessionId: String

    public init(sessionId: String) {
      self.sessionId = sessionId
    }
  }

  public init(
    actorSystem: ClusterSystem,
    sessionId: String
  ) {
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

  public static func spawn(on actorSystem: DistributedCluster.ClusterSystem, dependency: any Sendable & Codable) async throws -> Compressor {
    guard let typedDependency = dependency as? Dependency else {
      throw VirtualActorError.spawnDependencyTypeMismatch
    }
    return Compressor(
      actorSystem: actorSystem,
      sessionId: typedDependency.sessionId
    )
  }

  distributed public func fetch(id: String, urls: [URL], name: String, from session: Session) async throws -> String {
    let output = try await actorSystem.workflows.execute(
      type: FileCompressorWorkflow.self,
      options: .init(id: id),
      input: FileCompressorWorkflow.Input(
        urls: urls,
        archiveName: name,
        session: session
      )
    )
    // executionCompleted is now recorded — notify so the session sees the completed status
    try? await session.notify(.archieved(URL(fileURLWithPath: output.archivePath)))
    return output.archivePath
  }

  public func handleEvent(_ event: Event) {
    switch event {
    case .fileStarted(let name):
      self.files[name] = File(name: name, status: .started)
    case .fileFinished(let name):
      self.files[name] = File(name: name, status: .finished)
    }
  }
}

public distributed actor Session {

  public typealias ActorSystem = ClusterSystem

  public enum NotityMessage: Sendable, Codable {
    case started
    case download(file: URL, fileIndex: Int, fraction: Double)
    case archieved(URL)
  }

  private let onNotify: @Sendable (NotityMessage, [Int: Double]) async throws -> Void
  private var downloadFractions: [Int: Double] = [:]

  public init(
    actorSystem: ClusterSystem,
    onNotify: @escaping @Sendable (NotityMessage, [Int: Double]) async throws -> Void
  ) {
    self.actorSystem = actorSystem
    self.onNotify = onNotify
  }

  distributed public func notify(_ message: NotityMessage) async throws {
    if case .download(_, let index, let fraction) = message {
      downloadFractions[index] = fraction
    }
    try await onNotify(message, downloadFractions)
  }
}
