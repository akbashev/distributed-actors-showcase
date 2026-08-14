import Backend
import DistributedCluster
import EventSourcing
import PostgresEventStore
import ServiceLifecycle
import VirtualActors

struct Worker: Service {

  let clusterSystem: ClusterSystem

  init(
    port: Int,
    configuredWith configureSettings: sending (inout ClusterSystemSettings) -> Void
  ) async {
    self.clusterSystem = await ClusterSystem(
      "calculator-worker-\(port)", configuredWith: configureSettings)
  }
  func run() async throws {
    let worker = await CalculationWorker(
      actorSystem: clusterSystem,
      nodeLabel:
        "\(self.clusterSystem.cluster.endpoint.host):\(self.clusterSystem.cluster.endpoint.port)"
    )

    clusterSystem.log.info(
      "Worker node started with worker on \(self.clusterSystem.cluster.endpoint.host):\(self.clusterSystem.cluster.endpoint.port)"
    )

    try await clusterSystem.terminated
  }
}
