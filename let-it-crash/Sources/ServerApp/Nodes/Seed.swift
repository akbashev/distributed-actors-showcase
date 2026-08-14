import Backend
import DistributedCluster
import EventSourcing
import ServiceLifecycle
import VirtualActors

/// Runs the cluster daemon ("seed") role in-process.
struct Seed: Service {

  let store: any EventStore

  func run() async throws {
    let daemon = await ClusterSystem.startClusterDaemon { [store] settings in
      settings.plugins.install(plugin: ClusterSingletonPlugin())
      settings.plugins.install(plugin: ClusterVirtualActorsPlugin())
      settings.plugins.install(plugin: ClusterJournalPlugin { _ in store })
    }
    let system = daemon.system
    system.log.info(
      "Seed Node is running",
      metadata: [
        "node/id": "\(system.cluster.node)",
        "bind/host": "\(system.settings.endpoint.host)",
        "bind/port": "\(system.settings.endpoint.port)",
      ])
    _ = try await system.terminated
  }
}
