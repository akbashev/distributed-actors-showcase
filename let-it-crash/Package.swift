// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "let-it-crash",
  platforms: [
    .macOS("26.0")
  ],
  products: [
    .executable(name: "calculator-web", targets: ["ServerApp"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.6.0"),
    .package(url: "https://github.com/akbashev/cluster-event-sourcing.git", branch: "main"),
    .package(url: "https://github.com/akbashev/cluster-virtual-actors.git", branch: "main"),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.16.0"),
    .package(
      url: "https://github.com/hummingbird-community/hummingbird-elementary.git", from: "0.4.2"),
    .package(url: "https://github.com/elementary-swift/elementary.git", from: "0.6.0"),
    .package(url: "https://github.com/apple/swift-distributed-actors.git", branch: "main"),
    .package(url: "https://github.com/akbashev/postgres-event-store.git", branch: "main"),

    .package(path: "../remote"),
  ],
  targets: [
    .target(
      name: "Backend",
      dependencies: [
        .product(name: "EventSourcing", package: "cluster-event-sourcing"),
        .product(name: "VirtualActors", package: "cluster-virtual-actors"),
        .product(name: "DistributedCluster", package: "swift-distributed-actors"),
      ]
    ),
    .target(
      name: "WebApp",
      dependencies: [
        "Backend",
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdElementary", package: "hummingbird-elementary"),
        .product(name: "Elementary", package: "elementary"),
      ],
      resources: [
        .copy("Public")
      ]
    ),
    .executableTarget(
      name: "ServerApp",
      dependencies: [
        "Backend",
        "WebApp",
        .product(name: "SeedNode", package: "remote"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
        .product(name: "EventSourcing", package: "cluster-event-sourcing"),
        .product(name: "VirtualActors", package: "cluster-virtual-actors"),
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "DistributedCluster", package: "swift-distributed-actors"),
        .product(name: "PostgresEventStore", package: "postgres-event-store"),
      ]
    ),
  ]
)
