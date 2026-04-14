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

  func run() async throws {
    let config = try StoreConfiguration(databaseURL: databaseURL)
    try await Self.runApp(store: config.store, postgresClient: config.postgresClient)
  }

  static func runApp(store: any EventStore, postgresClient: PostgresClient?) async throws {
    let clusterPort = 4660
    let httpPort = 8080
    let webPort = 8081
    let host = "127.0.0.1"

    let seamless = await SeamlessBackend {
      let plugins: [any Plugin] = [
        ClusterSingletonPlugin(),
        ClusterVirtualActorsPlugin(),
        ClusterJournalPlugin { _ in store },
      ]
      $0.bindPort = clusterPort
      $0.discovery = .clusterd
      for plugin in plugins { $0.plugins.install(plugin: plugin) }
    }
    let runtime = await SeamlessBackend.HTTPServer(
      configuration: .init(host: host, port: httpPort),
      schemas: [TripPlan.self, EmojiReaction.self]
    ) {
      let plugins: [any Plugin] = [
        ClusterSingletonPlugin(),
        ClusterVirtualActorsPlugin(),
        ClusterJournalPlugin { _ in store },
      ]
      $0.bindPort = clusterPort + 1
      $0.discovery = .clusterd
      for plugin in plugins { $0.plugins.install(plugin: plugin) }
    }

    try await withThrowingDiscardingTaskGroup { group in
      if let postgresClient {
        group.addTask { await postgresClient.run() }
        group.addTask { try await (store as? PostgresEventStore)?.setupDatabase() }
      }
      group.addTask { try await runtime.run() }
      group.addTask { try await seamless.run() }
      group.addTask {
        let daemon = await ClusterSystem.startClusterDaemon {
          let plugins: [any Plugin] = [
            ClusterSingletonPlugin(),
            ClusterVirtualActorsPlugin(),
            ClusterJournalPlugin { _ in store },
          ]
          for plugin in plugins { $0.plugins.install(plugin: plugin) }
        }
        return try await daemon.terminated
      }
      group.addTask { try await WorkersNode().run() }
      group.addTask {
        try await WebApp(
          host: host,
          httpPort: httpPort,
          webPort: webPort
        ).run()
      }
    }
  }
}

struct StoreConfiguration {
  let store: any EventStore
  let postgresClient: PostgresClient?

  public init(databaseURL: String?) throws {
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
      self.store = PostgresEventStore(client: client)
      self.postgresClient = client
    } else {
      let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("seamless-llms/journal")
      self.store = try FileEventStore(directory: dir)
      self.postgresClient = nil
    }
  }
}

enum ConversationBackendError: Swift.Error {
  case invalidDatabaseUrl(String?)
}
