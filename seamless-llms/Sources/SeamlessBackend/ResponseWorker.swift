import DistributedCluster
import SeamlessCore

public distributed actor ResponseWorker<S: SeamlessCore.SeamlessSchema>: DistributedWorker {

  public typealias ActorSystem = ClusterSystem
  public typealias WorkItem = String
  public typealias WorkResult = S

  public let engine: SeamlessEngine

  public init(actorSystem: ActorSystem) async throws {
    self.actorSystem = actorSystem
    self.engine = try SeamlessEngine(isRemote: true)
    await self.actorSystem.receptionist.checkIn(self, with: .responseWorker(for: S.self))
  }

  distributed public func submit(work: String) async throws -> S {
    try await self.engine.respond(to: work)
  }
}

extension DistributedReception.Key {
  public static func responseWorker<S: SeamlessCore.SeamlessSchema>(for type: S.Type) -> DistributedReception.Key<ResponseWorker<S>> {
    .init(id: "seamless-response-workers-\(String(describing: S.self))")
  }
}
