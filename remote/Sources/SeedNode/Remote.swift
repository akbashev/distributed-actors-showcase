import DistributedCluster
import EventSourcing
import PostgresEventStore
import PostgresNIO
import ServiceLifecycle
import VirtualActors

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct SeedNode: Service {
  public enum SeedNodeError: Error, CustomStringConvertible {
    case invalidPort(String)
    case invalidDatabaseUrl(String?)

    public var description: String {
      switch self {
      case .invalidPort(let port):
        "Invalid BIND_PORT: \(port). Please provide a valid integer."
      case .invalidDatabaseUrl(.some(let url)):
        "Invalid database URL: \(url). Please provide a valid URL."
      case .invalidDatabaseUrl(.none):
        "Database URL is missing. Please provide a valid URL."
      }
    }
  }

  public struct Environment: Sendable {
    public let database: Database

    public struct Database: Sendable {
      public let host: String
      public let port: Int
      public let username: String
      public let password: String?
      public let name: String?
      public let tls: Bool
    }

    public init(database: Database) {
      self.database = database
    }
  }

  public init() {}

  public func run() async throws {
    let environment = try Environment()
    let client = PostgresClient(configuration: environment.database.dbConfig)
    let store = PostgresEventStore(client: client)
    let plugins: [any Plugin] = [
      ClusterSingletonPlugin(),
      ClusterVirtualActorsPlugin(),
      ClusterJournalPlugin { _ in store },
    ]
    let daemon = await ClusterSystem.startClusterDaemon { settings in
      for plugin in plugins {
        settings.plugins.install(plugin: plugin)
      }
    }
    let system = daemon.system
    system.log.info(
      "Seed Node is running",
      metadata: [
        "node/id": "\(system.cluster.node)",
        "bind/host": "\(system.settings.endpoint.host)",
        "bind/port": "\(system.settings.endpoint.port)",
      ])
    _ = try await (client.run(), system.terminated, store.setupDatabase())
  }
}

extension SeedNode.Environment {

  public init() throws {
    let environment = ProcessInfo.processInfo.environment
    let databaseURL = environment["DATABASE_URL"]
    let tls = (environment["DB_TLS"] ?? databaseURL != nil ? "true" : "false") == "true"
    guard let databaseURL, !databaseURL.isEmpty, let components = URLComponents(string: databaseURL)
    else {
      throw SeedNode.SeedNodeError.invalidDatabaseUrl(databaseURL)
    }
    self.database = Database(
      host: components.host ?? "localhost",
      port: components.port ?? 5432,
      username: components.user ?? "postgres",
      password: components.password,
      name: components.path.trimmingCharacters(in: ["/"]),
      tls: tls
    )
  }
}

extension SeedNode.Environment.Database {
  public var dbConfig: PostgresClient.Configuration {
    .init(
      host: self.host,
      port: self.port,
      username: self.username,
      password: self.password,
      database: self.name,
      tls: self.tls ? .require(.makeClientConfiguration()) : .disable
    )
  }
}
