import Distributed
import DistributedCluster
import DurableWorkflows
import Foundation
import VirtualActors

public distributed actor Connection {
  public typealias ActorSystem = ClusterSystem

  private let response: @Sendable ([BookingMessage.SystemUpdate]) async throws -> Void
  fileprivate let user: UserActor
  private let _sessionId: String

  distributed public var sessionId: String { self._sessionId }

  public init(
    actorSystem: ActorSystem,
    sessionId: String,
    response: @escaping @Sendable ([BookingMessage.SystemUpdate]) async throws -> Void
  ) async throws {
    self.actorSystem = actorSystem
    self.response = response
    self._sessionId = sessionId
    self.user = try await actorSystem.virtualActors.getActor(
      identifiedBy: .init(rawValue: "user-\(sessionId)"),
      dependency: UserActor.Dependency(username: sessionId)
    )
  }

  distributed public func send(message: BookingMessage.UserAction) async throws {
    try await self.user.send(message: message, from: self)
  }

  distributed public func broadcast(_ events: [BookingMessage.SystemUpdate]) async throws {
    try await self.response(events)
  }
}
