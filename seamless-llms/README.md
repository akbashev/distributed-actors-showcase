# seamless-llms

A research project exploring seamless execution of LLM tasks across local and remote backends, built on top of [swift-distributed-actors](https://github.com/apple/swift-distributed-actors), [cluster-event-sourcing](https://github.com/akbashev/cluster-event-sourcing), [cluster-virtual-actors](https://github.com/akbashev/cluster-virtual-actors), and Apple's [FoundationModels](https://developer.apple.com/documentation/foundationmodels).

The core idea: an LLM call should be able to run locally on-device or on a remote backend, with the routing decision made transparently — the caller doesn't know or care which one ran. This was a few-days experiment, not a production system.

## Concepts

**SeamlessSchema** — a protocol that defines what the model should generate. Conforms to `@Generable` (FoundationModels) and `Codable`. Carries a static `identifier` used to route requests to the right schema on the backend, and optional `instructions` for the model.

**SeamlessClient** — the main entry point. Configured with an execution target (`.local`, `.remote`, or `.localAndRemote`). In `.localAndRemote` mode, it uses a local complexity classifier to decide which backend handles each request — simple prompts run on-device, complex ones are routed to the remote cluster.

**SeamlessEngine** — the local execution engine backed by FoundationModels. Holds a `LanguageModelSession` per conversation and generates typed, streaming responses directly on-device.

**Session** — a distributed, event-sourced virtual actor on the backend. Manages one conversation: persists messages and transcripts to the event log, broadcasts updates to all connected clients, and survives node restarts.

**SessionService** — the HTTP/WebSocket gateway on the backend. Routes incoming connections to the right `Session` actor via virtual actor lookup.

## Execution targets

| | **`.local`** | **`.remote`** | **`.localAndRemote`** |
|---|---|---|---|
| **Engine** | FoundationModels on-device | Distributed actor cluster | Both, routed by complexity |
| **Persistence** | None (session in memory) | Event log (survives restarts) | Remote (source of truth); local syncs |
| **Streaming** | Native `AsyncThrowingStream` | JSONL over HTTP | Unified stream from both |
| **Transcript sync** | — | — | Server → client on connect; client → server after completion |

## Requirements

- Swift 6.2+
- macOS 26+ (FoundationModels is macOS-only; the backend also runs on macOS)

## Installation

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/akbashev/distributed-actors-showcase.git", branch: "main"),
],
targets: [
    .target(
        name: "MyTarget",
        dependencies: [
            .product(name: "SeamlessClient", package: "distributed-actors-showcase"),
        ]
    ),
]
```

## Usage

### 1. Define a schema

```swift
import FoundationModels
import SeamlessCore

@Generable
struct TripPlan: SeamlessSchema {
    static let identifier = "trip.plan.v1"
    static let instructions: String? = "Create a 3-day itinerary from this request"

    @Guide(description: "An exciting name for the trip.")
    let title: String

    @Guide(description: "City or place this trip is about.")
    let destination: String

    @Guide(description: "A concise summary of the trip.")
    let summary: String
}
```

### 2. Create a client

```swift
import SeamlessClient

// Local only — runs entirely on-device via FoundationModels
let client = try SeamlessClient(configuration: .init(target: .local))

// Remote only — all calls go to the backend cluster
let client = try SeamlessClient(configuration: .init(target: .remote(backendURL)))

// Both — complexity classifier picks the backend per request
let client = try SeamlessClient(configuration: .init(target: .localAndRemote(backendURL)))
```

### 3. Stream a conversation

```swift
// Open a stream for a session
let stream: AsyncThrowingStream<SeamlessMessage<TripPlan>, Error> = try await client.stream(
    sessionId: "conversation-123"
)

// Send a message
try await client.send(TripPlan.self, sessionId: "conversation-123", inputText: "Plan a trip to Kyoto")

// Consume the stream
for try await message in stream {
    switch message {
    case .user(let userMessage):
        print("User: \(userMessage)")
    case .assistant(let assistantMessage):
        switch assistantMessage {
        case .partial(let data, _, _):
            print("Streaming: \(data.title ?? "...")")
        case .completed(let data, _, _):
            print("Done: \(data.title) — \(data.destination)")
        case .error(let text, _, _):
            print("Error: \(text)")
        default:
            break
        }
    }
}

// Disconnect when done
await client.disconnect(sessionId: "conversation-123")
```

### 4. One-shot response

One-shot responses go through the `/execute` endpoint on the backend, which is served by a pool of `ResponseWorker` actors. You need at least one worker node running for this to work.

```swift
let plan: TripPlan = try await client.respond(to: "Plan a weekend trip to Tokyo")
print(plan.title)
```

### 5. Start the backend

The backend has two parts: the HTTP server that handles client connections, and a separate worker node that executes one-shot requests. Workers run on a separate `ClusterSystem` and join the cluster automatically.

> [!IMPORTANT]
> Every schema you want clients to use must be registered in `schemas:` when starting the server. The backend uses the schema's `identifier` to route incoming requests to the correct type and model instructions. Unregistered schemas will be rejected.

```swift
import SeamlessBackend

let server = await SeamlessBackend.HTTPServer(
    configuration: .init(host: "0.0.0.0", port: 8080),
    schemas: [TripPlan.self] // register schemas
) {
    $0.plugins.install(plugin: ClusterSingletonPlugin())
    $0.plugins.install(plugin: ClusterVirtualActorsPlugin())
    $0.plugins.install(plugin: ClusterJournalPlugin { _ in eventStore })
}

// Worker node — executes one-shot `respond(to:)` requests
let workerSystem = await ClusterSystem("workers") {
    $0.discovery = .clusterd
}
var workers: [ResponseWorker<TripPlan>] = []
for _ in 0..<4 {
    workers.append(try await ResponseWorker(actorSystem: workerSystem))
}

try await withThrowingDiscardingTaskGroup { group in
    group.addTask { try await server.run() }
    group.addTask { try await workerSystem.terminated }
}
```

## Durability

Sessions are event-sourced virtual actors. When a client reconnects, the session replays its event log and broadcasts recent messages immediately. The local `LanguageModelSession` transcript is synced from the server on connect, so the on-device model picks up context it didn't generate itself.

## License

Apache 2.0 — see [LICENSE.txt](LICENSE.txt).
