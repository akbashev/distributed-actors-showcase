import ArgumentParser
import Backend
import DistributedCluster
import EventSourcing
import Foundation
import PostgresEventStore
import PostgresNIO
import SeedNode
import VirtualActors

@main
struct App: AsyncParsableCommand {

  enum StartupError: Error, CustomStringConvertible {
    case portInUse(host: String, port: Int)
    case unsupportedHost(String)
    case invalidPort(String)

    var description: String {
      switch self {
      case .portInUse(let host, let port):
        "Port \(port) on \(host) is already in use."
      case .unsupportedHost(let host):
        "Unsupported host '\(host)'. Use an IPv4 address like 127.0.0.1."
      case .invalidPort(let port):
        "Invalid BIND_PORT: \(port). Please provide a valid integer."
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

  func run() async throws {
    let environment = try SeedNode.Environment()
    let client = PostgresClient(configuration: environment.database.dbConfig)
    let store = PostgresEventStore(client: client)
    let plugins: [any Plugin] = [
      ClusterSingletonPlugin(),
      ClusterVirtualActorsPlugin(),
      ClusterJournalPlugin { _ in store },
    ]

    switch self.node {
    case .seed:
      try await SeedNode().run()
    case .frontend:
      try await Frontend(
        host: Self.bindHost,
        webPort: self.port
      ) {
        $0.bindPort = Self.frontendClusterPort
        $0.discovery = .clusterd
        for plugin in plugins {
          $0.plugins.install(plugin: plugin)
        }
      }.run()
    case .worker:
      try await Worker(port: self.port) {
        $0.bindHost = Self.bindHost
        $0.bindPort = self.port
        $0.discovery = .clusterd
        for plugin in plugins {
          $0.plugins.install(plugin: plugin)
        }
      }.run()
    case .client:
      try await Client(port: Self.clientClusterPort) {
        $0.bindPort = Self.clientClusterPort
        $0.discovery = .clusterd
        for plugin in plugins {
          $0.plugins.install(plugin: plugin)
        }
      }.run()
    case .standalone:
      try await withThrowingDiscardingTaskGroup { group in
        group.addTask {
          try await SeedNode().run()
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
}
