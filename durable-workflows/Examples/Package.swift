// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "travel-booking-example",
  platforms: [
    .macOS("26.0")
  ],
  products: [
    .library(name: "TravelBooking", targets: ["TravelBooking"]),
    .executable(name: "durable-workflows-demo", targets: ["DurableWorkflowsDemo"]),
  ],
  dependencies: [
    .package(path: ".."),
    .package(url: "https://github.com/akbashev/cluster-event-sourcing.git", branch: "main"),
    .package(url: "https://github.com/akbashev/cluster-virtual-actors.git", branch: "main"),
    .package(url: "https://github.com/apple/swift-distributed-actors.git", branch: "main"),
    .package(url: "https://github.com/akbashev/postgres-event-store.git", branch: "main"),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.16.0"),
    .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.2.0"),
    .package(url: "https://github.com/hummingbird-community/hummingbird-elementary.git", from: "0.4.2"),
    .package(url: "https://github.com/elementary-swift/elementary.git", from: "0.6.0"),
    .package(url: "https://github.com/elementary-swift/elementary-htmx.git", from: "0.1.0"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
  ],
  targets: [
    .target(
      name: "TravelBooking",
      dependencies: [
        .product(name: "DurableWorkflows", package: "durable-workflows"),
        .product(name: "EventSourcing", package: "cluster-event-sourcing"),
        .product(name: "VirtualActors", package: "cluster-virtual-actors"),
        .product(name: "DistributedCluster", package: "swift-distributed-actors"),
      ],
      path: "TravelBooking"
    ),
    .executableTarget(
      name: "DurableWorkflowsDemo",
      dependencies: [
        "TravelBooking",
        .product(name: "DurableWorkflows", package: "durable-workflows"),
        .product(name: "EventSourcing", package: "cluster-event-sourcing"),
        .product(name: "VirtualActors", package: "cluster-virtual-actors"),
        .product(name: "DistributedCluster", package: "swift-distributed-actors"),
        .product(name: "PostgresEventStore", package: "postgres-event-store"),
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
        .product(name: "HummingbirdElementary", package: "hummingbird-elementary"),
        .product(name: "Elementary", package: "elementary"),
        .product(name: "ElementaryHTMX", package: "elementary-htmx"),
        .product(name: "ElementaryHTMXWS", package: "elementary-htmx"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ],
      path: "DurableWorkflowsDemo",
      resources: [
        .copy("Public")
      ]
    ),
  ]
)
