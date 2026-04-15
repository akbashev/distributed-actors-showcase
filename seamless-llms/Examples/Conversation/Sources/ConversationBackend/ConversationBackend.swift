import ArgumentParser
import ConversationWebApp
import DistributedCluster
import EventSourcing
import Foundation
import Hummingbird
import PostgresEventStore
import PostgresNIO
import SeamlessBackend
import SeamlessClient
import SeamlessCore
import ServiceLifecycle
import SharedModels
import VirtualActors

@main
struct ConversationBackend: AsyncParsableCommand {
  @Option(name: .customLong("database-url"), help: "PostgreSQL connection URL. If omitted, uses file-based storage.")
  var databaseURL: String?

  @Option(help: "Host to bind to.")
  var host: String = NetworkConfiguration.defaultHost

  @Option(name: .customLong("cluster-port"), help: "Base cluster port.")
  var clusterPort: Int = NetworkConfiguration.defaultClusterPort

  @Option(name: .customLong("http-port"), help: "HTTP API port.")
  var httpPort: Int = NetworkConfiguration.defaultHttpPort

  @Option(name: .customLong("web-port"), help: "Web app port.")
  var webPort: Int = NetworkConfiguration.defaultWebPort

  func run() async throws {
    let store = try StoreConfiguration.make(databaseURL: databaseURL)
    let network = NetworkConfiguration(host: host, clusterPort: clusterPort, httpPort: httpPort, webPort: webPort)
    try await Self.runApp(store: store, network: network)
  }

  static func runApp(store: StoreConfiguration, network: NetworkConfiguration = .init()) async throws {
    let (eventStore, postgresClient): (any EventStore, PostgresClient?) =
      switch store {
      case .file(let s): (s, nil)
      case .postgres(let s, let c): (s, c)
      }

    let seamless = await SeamlessBackend {
      let plugins: [any Plugin] = [
        ClusterSingletonPlugin(),
        ClusterVirtualActorsPlugin(),
        ClusterJournalPlugin { _ in eventStore },
      ]
      $0.bindPort = network.clusterPort
      $0.discovery = .clusterd
      for plugin in plugins { $0.plugins.install(plugin: plugin) }
    }
      
    let runtime = await SeamlessBackend.HTTPServer(
      configuration: .init(host: network.host, port: network.httpPort),
      schemas: [TripPlan.self, EmojiReaction.self]
    ) {
      let plugins: [any Plugin] = [
        ClusterSingletonPlugin(),
        ClusterVirtualActorsPlugin(),
        ClusterJournalPlugin { _ in eventStore },
      ]
      $0.bindPort = network.clusterPort + 1
      $0.discovery = .clusterd
      for plugin in plugins { $0.plugins.install(plugin: plugin) }
    }

    try await withThrowingDiscardingTaskGroup { group in
      if let postgresClient {
        group.addTask { await postgresClient.run() }
        group.addTask { try await (eventStore as? PostgresEventStore)?.setupDatabase() }
      }
      group.addTask { try await runtime.run() }
      group.addTask { try await seamless.run() }
      group.addTask {
        let daemon = await ClusterSystem.startClusterDaemon {
          let plugins: [any Plugin] = [
            ClusterSingletonPlugin(),
            ClusterVirtualActorsPlugin(),
            ClusterJournalPlugin { _ in eventStore },
          ]
          for plugin in plugins { $0.plugins.install(plugin: plugin) }
        }
        return try await daemon.terminated
      }
      group.addTask { try await WorkersNode().run() }
      group.addTask {
        try await WebApp(
          host: network.host,
          httpPort: network.httpPort,
          webPort: network.webPort
        ).run()
      }
    }
  }
}

struct NetworkConfiguration {
  static let defaultHost = "127.0.0.1"
  static let defaultClusterPort = 4660
  static let defaultHttpPort = 8080
  static let defaultWebPort = 8081

  let host: String
  let clusterPort: Int
  let httpPort: Int
  let webPort: Int

  init(
    host: String = defaultHost,
    clusterPort: Int = defaultClusterPort,
    httpPort: Int = defaultHttpPort,
    webPort: Int = defaultWebPort
  ) {
    self.host = host
    self.clusterPort = clusterPort
    self.httpPort = httpPort
    self.webPort = webPort
  }
}

enum StoreConfiguration {
  case file(FileEventStore)
  case postgres(PostgresEventStore, PostgresClient)

  static func make(databaseURL: String?) throws -> StoreConfiguration {
    if let databaseURL {
      guard !databaseURL.isEmpty, let components = URLComponents(string: databaseURL) else {
        throw ConversationBackendError.invalidDatabaseUrl(databaseURL)
      }
      let tls = (ProcessInfo.processInfo.environment["DB_TLS"] ?? "false") == "true"
      let client = PostgresClient(
        configuration: .init(
          host: components.host ?? "localhost",
          port: components.port ?? 5432,
          username: components.user ?? "postgres",
          password: components.password,
          database: components.path.trimmingCharacters(in: ["/"]),
          tls: tls ? .require(.makeClientConfiguration()) : .disable
        )
      )
      return .postgres(PostgresEventStore(client: client), client)
    } else {
      let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("seamless-llms/journal")
      return .file(try FileEventStore(directory: dir))
    }
  }

}

enum ConversationBackendError: Swift.Error {
  case invalidDatabaseUrl(String?)
}
