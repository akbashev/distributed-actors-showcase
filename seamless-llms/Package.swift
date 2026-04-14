import CompilerPluginSupport
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "seamless-llms",
  platforms: [
    .iOS("26.0"),
    .macOS("26.0"),
  ],
  products: [
    .library(name: "SeamlessAPI", targets: ["SeamlessAPI"]),
    .library(name: "SeamlessClient", targets: ["SeamlessClient"]),
    .library(name: "SeamlessBackend", targets: ["SeamlessBackend"]),
    .library(name: "SeamlessCore", targets: ["SeamlessCore"]),
  ],
  dependencies: [
    .package(url: "https://github.com/akbashev/cluster-event-sourcing.git", branch: "main"),
    .package(url: "https://github.com/akbashev/cluster-virtual-actors.git", branch: "main"),
    .package(url: "https://github.com/apple/swift-distributed-actors.git", branch: "main"),
    .package(url: "https://github.com/apple/swift-openapi-generator.git", from: "1.10.0"),
    .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.9.0"),
    .package(url: "https://github.com/apple/swift-openapi-urlsession.git", from: "1.1.0"),
    .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.0.0"),
    .package(url: "https://github.com/swift-server/swift-openapi-hummingbird.git", from: "2.0.0"),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.16.0"),
    .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.2.0"),
  ],
  targets: [
    .target(
      name: "SeamlessAPI",
      dependencies: [
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime")
      ],
      plugins: [
        .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
      ]
    ),
    .target(
      name: "SeamlessClient",
      dependencies: [
        "SeamlessAPI",
        "SeamlessCore",
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
        .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
        .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
      ],
      plugins: [
        .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
      ]
    ),
    .target(
      name: "SeamlessBackend",
      dependencies: [
        "SeamlessAPI",
        "SeamlessCore",
        .product(name: "EventSourcing", package: "cluster-event-sourcing"),
        .product(name: "VirtualActors", package: "cluster-virtual-actors"),
        .product(name: "DistributedCluster", package: "swift-distributed-actors"),
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
        .product(name: "OpenAPIHummingbird", package: "swift-openapi-hummingbird"),
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
      ],
      plugins: [
        .plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")
      ]
    ),
    .target(
      name: "SeamlessCore"
    ),
  ]
)
