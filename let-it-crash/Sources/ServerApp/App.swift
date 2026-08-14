import ArgumentParser
import Backend
import DistributedCluster
import EventSourcing
import Foundation
import PostgresEventStore
import PostgresNIO
import VirtualActors

@main
struct App: AsyncParsableCommand {

  enum StartupError: Error, CustomStringConvertible {
    case portInUse(host: String, port: Int)
    case unsupportedHost(String)
    case invalidPort(String)
    case invalidDatabaseUrl(String)

    var description: String {
      switch self {
      case .portInUse(let host, let port):
        "Port \(port) on \(host) is already in use."
      case .unsupportedHost(let host):
        "Unsupported host '\(host)'. Use an IPv4 address like 127.0.0.1."
      case .invalidPort(let port):
        "Invalid BIND_PORT: \(port). Please provide a valid integer."
      case .invalidDatabaseUrl(let url):
        "Invalid database URL: \(url). Please provide a valid URL."
      }
    }
  }

  enum Node: String, ExpressibleByArgument {
    case frontend
    case worker
    case client
    case standalone
    case seed
  }

  @Argument var node: Node
  @Option var port: Int = 8080
  @Option(
    name: .customLong("database-url"),
    help: "PostgreSQL connection URL. If omitted, uses file-based storage.")
  var databaseURL: String?

  func run() async throws {
    let (store, postgresClient) = try Self.makeEventStore(databaseURL: self.databaseURL)

    try await withThrowingDiscardingTaskGroup { group in
      if let postgresClient {
        group.addTask { await postgresClient.run() }
        group.addTask { _ = try await (store as? PostgresEventStore)?.setupDatabase() }
      }
      group.addTask {
        try await self.runNode(store: store)
      }
    }
  }

  private func runNode(store: any EventStore) async throws {
    switch self.node {
    case .seed:
      try await Seed(store: store).run()
    case .frontend:
      try await Frontend(
        host: Self.bindHost,
        webPort: self.port
      ) {
        $0.bindPort = Self.frontendClusterPort
        $0.discovery = .clusterd
        $0.plugins.install(plugin: ClusterSingletonPlugin())
        $0.plugins.install(plugin: ClusterVirtualActorsPlugin())
        $0.plugins.install(plugin: ClusterJournalPlugin { _ in store })
      }.run()
    case .worker:
      try await Worker(port: self.port) {
        $0.bindHost = Self.bindHost
        $0.bindPort = self.port
        $0.discovery = .clusterd
        $0.plugins.install(plugin: ClusterSingletonPlugin())
        $0.plugins.install(plugin: ClusterVirtualActorsPlugin())
        $0.plugins.install(plugin: ClusterJournalPlugin { _ in store })
      }.run()
    case .client:
      try await Client(port: Self.clientClusterPort) {
        $0.bindPort = Self.clientClusterPort
        $0.discovery = .clusterd
        $0.plugins.install(plugin: ClusterSingletonPlugin())
        $0.plugins.install(plugin: ClusterVirtualActorsPlugin())
        $0.plugins.install(plugin: ClusterJournalPlugin { _ in store })
      }.run()
    case .standalone:
      try await withThrowingDiscardingTaskGroup { group in
        group.addTask {
          try await Seed(store: store).run()
        }
        group.addTask {
          try await Client(port: Self.clientClusterPort) {
            let plugins: [any Plugin] = [
              ClusterSingletonPlugin(),
              ClusterVirtualActorsPlugin(),
              ClusterJournalPlugin { _ in store },
            ]
            $0.bindPort = Self.clientClusterPort
            $0.discovery = .clusterd
            for plugin in plugins {
              $0.plugins.install(plugin: plugin)
            }
          }.run()
        }
        group.addTask {
          try await Frontend(
            host: Self.bindHost,
            webPort: self.port
          ) {
            let plugins: [any Plugin] = [
              ClusterSingletonPlugin(),
              ClusterVirtualActorsPlugin(),
              ClusterJournalPlugin { _ in store },
            ]
            $0.bindPort = Self.frontendClusterPort
            $0.discovery = .clusterd
            for plugin in plugins {
              $0.plugins.install(plugin: plugin)
            }
          }.run()
        }
        group.addTask {
          try await Worker(port: self.port) {
            let plugins: [any Plugin] = [
              ClusterSingletonPlugin(),
              ClusterVirtualActorsPlugin(),
              ClusterJournalPlugin { _ in store },
            ]
            $0.bindHost = Self.bindHost
            $0.bindPort = Self.clientClusterPort + 1
            $0.discovery = .clusterd
            for plugin in plugins {
              $0.plugins.install(plugin: plugin)
            }
          }.run()
        }
      }
    }
  }
}

extension App {
  static let bindHost = "127.0.0.1"
  static let frontendClusterPort = 3650
  static let clientClusterPort = 3651

  /// Creates the event store: Postgres when a database URL is given (via
  /// `--database-url` or the `DATABASE_URL` environment variable), otherwise a
  /// file-based store under `~/Library/Application Support/calculator-web/journal`.
  static func makeEventStore(
    databaseURL: String?
  ) throws -> (store: any EventStore, client: PostgresClient?) {
    let resolvedURL = databaseURL ?? ProcessInfo.processInfo.environment["DATABASE_URL"]
    guard let resolvedURL, !resolvedURL.isEmpty else {
      let directory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("calculator-web/journal")
      return (try FileEventStore(directory: directory), nil)
    }
    guard let components = URLComponents(string: resolvedURL) else {
      throw StartupError.invalidDatabaseUrl(resolvedURL)
    }
    let tls = ProcessInfo.processInfo.environment["DB_TLS"] == "true"
    let client = PostgresClient(
      configuration: .init(
        host: components.host ?? "localhost",
        port: components.port ?? 5432,
        username: components.user ?? "postgres",
        password: components.password,
        database: components.path.trimmingCharacters(in: ["/"]),
        tls: tls ? .require(.makeClientConfiguration()) : .disable
      ))
    return (PostgresEventStore(client: client), client)
  }
}
