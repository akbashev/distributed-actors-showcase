import Distributed
import DistributedCluster
import EventSourcing
import Foundation
import FoundationModels
import ServiceLifecycle
import VirtualActors

public struct SeamlessBackend: Service {
  public let system: ClusterSystem
  public let node: VirtualNode

  public init(
    configuredWith configureSettings: sending (inout ClusterSystemSettings) -> Void
  ) async {
    self.system = await ClusterSystem("seamless-server-node", configuredWith: configureSettings)
    self.node = await VirtualNode(actorSystem: self.system)
  }

  public func run() async throws {
    try await node.run()
  }
}
