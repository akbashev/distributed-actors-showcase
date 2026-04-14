// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Conversation",
  platforms: [
    .iOS("26.0"),
    .macOS("26.0"),
  ],
  products: [
    .library(name: "SharedModels", targets: ["SharedModels"]),
    .library(name: "ConversationApp", targets: ["ConversationApp"]),
    .library(name: "ConversationWebApp", targets: ["ConversationWebApp"]),
    .executable(name: "conversation-backend", targets: ["ConversationBackend"]),
  ],
  dependencies: [
    .package(path: "../.."),
    .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.16.0"),
    .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.2.0"),
    .package(url: "https://github.com/hummingbird-community/hummingbird-elementary.git", from: "0.4.2"),
    .package(url: "https://github.com/elementary-swift/elementary-htmx.git", from: "0.5.0"),
    .package(url: "https://github.com/akbashev/postgres-event-store.git", branch: "main"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
  ],
  targets: [
    .target(
      name: "SharedModels",
      dependencies: [
        .product(name: "SeamlessCore", package: "seamless-llms")
      ]
    ),
    .target(
      name: "ConversationApp",
      dependencies: [
        "SharedModels",
        .product(name: "SeamlessClient", package: "seamless-llms"),
      ]
    ),
    .executableTarget(
      name: "ConversationBackend",
      dependencies: [
        "SharedModels",
        "ConversationWebApp",
        .product(name: "SeamlessBackend", package: "seamless-llms"),
        .product(name: "SeamlessClient", package: "seamless-llms"),
        .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
        .product(name: "PostgresEventStore", package: "postgres-event-store"),
        .product(name: "ArgumentParser", package: "swift-argument-parser"),
      ]
    ),
    .target(
      name: "ConversationWebApp",
      dependencies: [
        .product(name: "Hummingbird", package: "hummingbird"),
        .product(name: "HummingbirdElementary", package: "hummingbird-elementary"),
        .product(name: "ElementaryHTMX", package: "elementary-htmx"),
        .product(name: "ElementaryHTMXWS", package: "elementary-htmx"),
        .product(name: "SeamlessBackend", package: "seamless-llms"),
      ],
      resources: [
        .copy("Public")
      ]
    ),
  ]
)
