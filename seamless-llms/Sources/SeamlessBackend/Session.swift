import Distributed
import DistributedCluster
import EventSourcing
import Foundation
import FoundationModels
import SeamlessAPI
import SeamlessCore
import VirtualActors

extension SeamlessBackend {

  public typealias SessionID = String

  @EventSourced
  distributed actor Session {

    typealias ActorSystem = ClusterSystem
    typealias Event = SeamlessBackend.StoreEvent

    struct Dependency: Codable, Sendable {
      let id: SessionID

      init(
        id: SessionID
      ) {
        self.id = id
      }
    }

    private let encoder: JSONEncoder = JSONEncoder()
    private let sessionId: SessionID
    private var recentMessages: [StreamMessage] = []
    private var connections: Set<AnyConnection> = []
    private var task: Task<Void, any Error>?
    private let engine: SeamlessEngine

    init(
      actorSystem: ClusterSystem,
      dependency: Dependency
    ) async throws {
      self.actorSystem = actorSystem
      self.sessionId = dependency.id
      self.engine = try SeamlessEngine(isRemote: true)
      try await actorSystem.journal.register(
        actor: self,
        with: "seamless-session-\(dependency.id)"
      )
    }

    distributed func sync<S: SeamlessCore.SeamlessSchema>(
      _ messages: [StreamMessage],
      transcript: Transcript?,
      from connection: Connection<S>
    ) async throws {
      for message in messages {
        try await self.emit(event: .message(message))
      }
      if let transcript {
        try await self.emit(event: .transcript(id: self.sessionId, transcript))
      }
    }

    distributed func send<S: SeamlessCore.SeamlessSchema>(
      message: StreamMessage.UserMessage,
      from connection: Connection<S>
    ) async throws {
      switch message {
      case .connected:
        self.task = Task {
          do {
            let stream: AsyncThrowingStream<SeamlessCore.SeamlessMessage<S>, Error> = await self.engine.connect(sessionId: self.sessionId)
            for try await value in stream {
              if let message: StreamMessage = try? StreamMessage(value, encoder: encoder) {
                switch message {
                case .user:
                  ()  // Already persisted and broadcast in send(.request)
                case .assistant(.completed(let data, let createdAt, let isRemote)):
                  try await self.emit(event: .message(message))
                  self.broadcast([message])
                default:
                  self.broadcast([message])
                }
              }
            }

            if let transcript = await self.engine.transcript(for: sessionId) {
              try await self.emit(event: .transcript(id: sessionId, transcript))
            }
          } catch {
            let errorMessage: StreamMessage = .assistant(
              .error(
                error.localizedDescription,
                createdAt: Date(),
                isRemote: true
              )
            )
            try await self.emit(
              event: .message(errorMessage)
            )
            self.broadcast([errorMessage])
          }
        }
        try await self.connections.insert(AnyConnection(connection))
        self.broadcast(self.recentMessages)
        if let transcript = await self.engine.transcript(for: self.sessionId),
          let data = try? JSONEncoder().encode(transcript)
        {
          self.broadcast([.assistant(.transcript(data, createdAt: Date()))])
        }
      case .request(let prompt, let createdAt):
        let message: StreamMessage = .user(message)
        try await self.emit(event: .message(message))
        self.broadcast([message])
        await self.engine.send(
          message: SeamlessCore.SeamlessMessage<S>.UserMessage.prompt(text: prompt, createdAt: createdAt),
          to: sessionId
        )
      case .disconnected:
        guard let connection = try? await AnyConnection(connection) else { return }
        self.connections.remove(connection)
        self.task?.cancel()
        self.task = nil
        if self.connections.isEmpty {
          await self.engine.disconnect(sessionId: self.sessionId)
        }
      }
    }

    private func remove(connection: AnyConnection) {
      self.connections.remove(connection)
    }

    private func broadcast(_ events: [StreamMessage]) {
      Task {
        await withDiscardingTaskGroup { group in
          for connection in self.connections {
            group.addTask {
              try? await connection.broadcast(events)
            }
          }
        }
      }
    }

    deinit {
      self.task?.cancel()
      self.task = nil
    }
  }
}

extension SeamlessBackend.Session: VirtualActor {

  static func spawn(
    on actorSystem: ClusterSystem,
    dependency: any Sendable & Codable
  ) async throws -> Self {
    guard let dependency = dependency as? Dependency else {
      throw VirtualActorError.spawnDependencyTypeMismatch
    }
    return try await Self(
      actorSystem: actorSystem,
      dependency: dependency
    )
  }

}

// Event sourced
extension SeamlessBackend.Session {

  distributed func handleEvent(_ event: Event) {
    switch event {
    case .message(let message):
      self.recentMessages.append(message)
    case let .transcript(id, transcript):
      Task { await self.engine.updateSession(with: id, transcript: transcript) }
    }
  }
}

extension SeamlessBackend.StreamMessage {
  fileprivate init<S: SeamlessCore.SeamlessSchema>(_ message: SeamlessCore.SeamlessMessage<S>, encoder: JSONEncoder) throws {
    switch message {
    case .user(let userMessage):
      switch userMessage {
      case let .prompt(text, createdAt):
        self = .user(.request(prompt: text, createdAt: createdAt))
      }
    case .assistant(let assistantMessage):
      switch assistantMessage {
      case let .error(text, createdAt, isRemote):
        self = .assistant(
          .error(
            text,
            createdAt: createdAt,
            isRemote: isRemote
          )
        )
      case let .partial(data, createdAt, isRemote):
        self = .assistant(
          .partial(
            try encoder.encode(data),
            createdAt: createdAt,
            isRemote: isRemote
          )
        )
      case let .completed(data, createdAt, isRemote):
        self = .assistant(
          .completed(
            try encoder.encode(data),
            createdAt: createdAt,
            isRemote: isRemote
          )
        )
      case .hearbeat(let createdAt):
        self = .assistant(
          .heartbeat(
            createdAt: createdAt
          )
        )
      case .transcript:
        throw SeamlessError.executionFailed("Transcript messages are not streamed")
      }
    }
  }
}
