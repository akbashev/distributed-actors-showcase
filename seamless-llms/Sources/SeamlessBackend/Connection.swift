import Distributed
import DistributedCluster
import Foundation
import FoundationModels
import SeamlessAPI
import SeamlessCore
import VirtualActors

extension SeamlessBackend {
  public distributed actor Connection<S: SeamlessCore.SeamlessSchema> {
    public typealias ActorSystem = ClusterSystem
    public let sessionID: String
    public let response: @Sendable ([SeamlessBackend.StreamMessage]) async throws -> Void
    private let session: Session

    public init(
      actorSystem: ClusterSystem,
      sessionID: String,
      response: @Sendable @escaping ([SeamlessBackend.StreamMessage]) async throws -> Void
    ) async throws {
      self.actorSystem = actorSystem
      self.sessionID = sessionID
      self.response = response
      self.session = try await actorSystem.virtualActors.getActor(
        identifiedBy: .init(rawValue: "seamless-session-\(sessionID)"),
        dependency: SeamlessBackend.Session.Dependency(id: self.sessionID)
      )
    }

    distributed public func send(message: StreamMessage.UserMessage) async throws {
      try await self.session.send(message: message, from: self)
    }

    distributed public func sync(messages: [StreamMessage], transcript: Transcript?) async throws {
      try await self.session.sync(messages, transcript: transcript, from: self)
    }

    distributed public func broadcast(_ messages: [StreamMessage]) async throws {
      try await self.response(messages)
    }

    distributed public func sessionId() async throws -> String {
      self.sessionID
    }
  }

  public struct AnyConnection: Hashable, Sendable {
    public let sessionID: String
    private let _send: @Sendable (SeamlessBackend.StreamMessage.UserMessage) async throws -> Void
    private let _sync: @Sendable ([SeamlessBackend.StreamMessage], Transcript?) async throws -> Void
    private let _broadcast: @Sendable ([SeamlessBackend.StreamMessage]) async throws -> Void

    public init<S: SeamlessCore.SeamlessSchema>(_ connection: SeamlessBackend.Connection<S>) async throws {
      self.sessionID = try await connection.sessionId()
      self._broadcast = { messages in
        try await connection.broadcast(messages)
      }
      self._send = { message in
        try await connection.send(message: message)
      }
      self._sync = { messages, transcript in
        try await connection.sync(messages: messages, transcript: transcript)
      }
    }

    public func send(message: SeamlessBackend.StreamMessage.UserMessage) async throws {
      try await _send(message)
    }

    public func sync(messages: [SeamlessBackend.StreamMessage], transcript: Transcript?) async throws {
      try await _sync(messages, transcript)
    }

    public func broadcast(_ messages: [SeamlessBackend.StreamMessage]) async throws {
      try await _broadcast(messages)
    }

    public static func == (lhs: AnyConnection, rhs: AnyConnection) -> Bool {
      lhs.sessionID == rhs.sessionID
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(self.sessionID)
    }
  }

}
