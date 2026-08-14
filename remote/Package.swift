// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "seed",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "SeedNode", targets: ["SeedNode"])
  ],
  dependencies: [
    .package(url: "https://github.com/akbashev/cluster-event-sourcing.git", branch: "main"),
    .package(url: "https://github.com/akbashev/cluster-virtual-actors.git", branch: "main"),
    .package(url: "https://github.com/akbashev/postgres-event-store.git", branch: "main"),
    .package(url: "https://github.com/apple/swift-distributed-actors.git", branch: "main"),
  ],
  targets: [
    .target(
      name: "SeedNode",
      dependencies: [
        .product(name: "EventSourcing", package: "cluster-event-sourcing"),
        .product(name: "VirtualActors", package: "cluster-virtual-actors"),
        .product(name: "PostgresEventStore", package: "postgres-event-store"),
        .product(name: "DistributedCluster", package: "swift-distributed-actors"),
      ]
    )
  ]
)
