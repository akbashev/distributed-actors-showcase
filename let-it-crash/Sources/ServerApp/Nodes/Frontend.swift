import Backend
import DistributedCluster
import EventSourcing
import Hummingbird
import PostgresEventStore
import ServiceLifecycle
import VirtualActors
import WebApp

public struct Frontend: Service {

  let host: String
  let webPort: Int
  public let clusterSystem: ClusterSystem

  public init(
    host: String,
    webPort: Int,
    configuredWith configureSettings: sending (inout ClusterSystemSettings) -> Void
  ) async {
    self.clusterSystem = await ClusterSystem(
      "calculator-frontend", configuredWith: configureSettings)
    self.host = host
    self.webPort = webPort
  }

  public func run() async throws {
    let clientLookup: @Sendable (Int) async throws -> Calculator = { clientId in
      try await clusterSystem.virtualActors.getActor(
        identifiedBy: .init(rawValue: "calculator-client-\(clientId)"),
        dependency: Calculator.Dependency(clientId: clientId)
      )
    }

    let router = Router()
    router.addMiddleware {
      FileMiddleware(WebAppAssets.publicRoot, searchForIndexHtml: false)
    }
    WebAppRoutes(clientLookup: clientLookup).register(on: router)

    let app = Application(
      router: router,
      configuration: .init(
        address: .hostname(self.host, port: webPort),
        serverName: "calculator-web"
      )
    )

    try await withThrowingDiscardingTaskGroup { group in
      group.addTask { try await app.runService() }
      group.addTask { try await clusterSystem.terminated }
    }
  }
}
