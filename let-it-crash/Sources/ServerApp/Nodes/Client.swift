import Backend
import DistributedCluster
import EventSourcing
import PostgresEventStore
import ServiceLifecycle
import VirtualActors

struct Client: Service {

  let clusterSystem: ClusterSystem

  init(
    port: Int,
    configuredWith configureSettings: sending (inout ClusterSystemSettings) -> Void
  ) async {
    self.clusterSystem = await ClusterSystem(
      "calculator-client-\(port)", configuredWith: configureSettings)
  }

  func run() async throws {
    let virtualNode = await VirtualNode(actorSystem: clusterSystem)
    try await virtualNode.run()
  }
}
