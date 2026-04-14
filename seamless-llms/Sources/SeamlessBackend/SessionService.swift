import AsyncAlgorithms
import DistributedCluster
import Foundation
import FoundationModels
import Hummingbird
import HummingbirdWebSocket
import Logging
import OpenAPIRuntime
import SeamlessAPI
import SeamlessCore
import ServiceLifecycle
import VirtualActors

public struct SessionService: Service {

  public enum Connection: Identifiable, Sendable {
    case jsonl(JSONLConnection)
    case websocket(WebSocketConnection)

    public var id: String {
      switch self {
      case .jsonl(let connection): connection.id
      case .websocket(let connection): connection.id
      }
    }

    func send(message: SeamlessBackend.StreamMessage.UserMessage) async throws {
      switch self {
      case .jsonl(let connection):
        try await connection.send(message: message)
      case .websocket(let connection):
        try await connection.send(message: message)
      }
    }

    func sync(messages: [SeamlessBackend.StreamMessage], transcript: Transcript?) async throws {
      switch self {
      case .jsonl(let connection):
        try await connection.sync(messages: messages, transcript: transcript)
      case .websocket(let connection):
        try await connection.sync(messages: messages, transcript: transcript)
      }
    }

    func finish() {
      switch self {
      case .jsonl(let connection):
        connection.outbound.finish()
      case .websocket(let connection):
        connection.outbound.finish()
      }
    }
  }

  /// An actor is used to manage the outbound connections in a thread safe manner
  /// This is required because the websocket connection can be opened and closed on different threads
  ///
  /// In a production setting, you would also want to use an event broker like Redis or Kafka of sorts.
  /// That way, you can horizontally scale your application by adding more instances of this service.
  actor OutboundConnections {

    enum Error: Swift.Error {
      case alreadyAdded
      case leaving
      case missingConnection
      case missingConversation
    }

    private var connections: [Connection.ID: Connection] = [:]
    private let logger: Logger

    func add(
      _ connection: Connection
    ) async throws {
      if self.connections[connection.id] != nil {
        self.logger.info("participant already exists", metadata: ["conversationId": .string(connection.id)])
        // remove and reconnect
        try await self.remove(connectionWithId: connection.id)
      }

      self.connections[connection.id] = connection
      do {
        try await connection.send(
          message: .connected(Date())
        )
      } catch {
        throw error
      }
    }

    func remove(_ connection: Connection) async throws {
      try await self.remove(connectionWithId: connection.id)
    }

    func remove(connectionWithId id: Connection.ID) async throws {
      guard let connection = self.connections[id] else { return }
      defer {
        self.connections[id] = nil
      }
      do {
        try await connection.send(
          message: .disconnected(Date())
        )
      } catch {
        throw error
      }
    }

    func send(_ message: SeamlessBackend.StreamMessage.UserMessage, to id: Connection.ID) async throws {
      guard let connection = self.connections[id] else {
        throw OutboundConnections.Error.missingConnection
      }
      try await connection.send(message: message)
    }

    func sync(_ messages: [SeamlessBackend.StreamMessage], transcript: Transcript?, to id: Connection.ID) async throws {
      guard let connection = self.connections[id] else {
        throw OutboundConnections.Error.missingConnection
      }
      try await connection.sync(messages: messages, transcript: transcript)
    }

    init(logger: Logger) {
      self.logger = logger
    }
  }

  /// A stream of new connections being accepted by the server
  let connectionStream: AsyncStream<Connection>
  /// A continuation for the connection stream, that can emit new signals
  private let connectionContinuation: AsyncStream<SessionService.Connection>.Continuation
  /// A logger for the connection manager
  let logger: Logger
  let actorSystem: ClusterSystem
  /// Encoder/Decoder
  let encoder = JSONEncoder()
  let decoder = JSONDecoder()
  // The OutboundConnections actor is used to manage the outbound connections in a thread safe manner
  // Allowing us to broadcast messages to all the connected clients
  let outboundConnections: OutboundConnections
  let typeLooker: [String: any SeamlessCore.SeamlessSchema.Type]
  private(set) var pools: [String: AnyWorkerPool] = [:]

  public func run() async throws {
    /// The `withGracefulShutdownHandler` is a helper that will call the `onGracefulShutdown` closure
    /// when the application is shutting down.
    ///
    /// This helps ensure that the application will not exit before the connection manager has a chance to
    /// clean up all the connections.
    await withGracefulShutdownHandler {
      /// The `withDiscardingTaskGroup` is a task group that can indefinitely add tasks to it.
      /// As opposed to a regular task group, it will not incur memory overhead for each task added.
      /// This allows it to scale for a large number of tasks.
      await withDiscardingTaskGroup { group in
        // As each client connects, the for loop will emit the next connection
        for await connection in self.connectionStream {
          // Each client connection is handled in a new task, so their work is parallelized
          group.addTask {
            self.logger.info(
              "add connection",
              metadata: ["conversationId": .string(connection.id)]
            )

            do {
              // Add the client to the list of connected clients
              try await self.outboundConnections.add(connection)
              try await self.handleMessages(from: connection)
            } catch {
              self.logger.error(Logger.Message(stringLiteral: error.localizedDescription))
            }
            // When the connection is closed, we remove the client from the list of connected clients
            self.logger.info("remove connection", metadata: ["conversationId": .string(connection.id)])
            try? await self.outboundConnections.remove(connection)
            connection.finish()
          }
        }

        // Once the server is shutting down, the for loop will finish
        // This leads to this line, where we cancel all the tasks in the task group
        // The cancellation will in turn close the `messages` iterator for each connection
        // That will ca                                                                          use all connections to be cleaned up, allowing the application to exit
        group.cancelAll()
      }
    } onGracefulShutdown: {
      /// Closes the connection stream, which will stop the server from handling new connections
      self.connectionContinuation.finish()
    }
  }

  private func handleMessages(from connection: Connection) async throws {
    switch connection {
    case .websocket(let webSocketConnection):

      // We handle the stream as incoming messages emitted by this client
      // The `for try await` loop will suspend until a new message is available
      // Once a message is available, the message is handled before awaiting the next one
      // This implicitly applies "backpressure" to the client, to prevent it from sending too many messages
      // which would've otherwise overwhelmed the server
      for try await input in webSocketConnection.inbound.messages(maxSize: 1_000_000) {
        // We only handle text messages
        switch input {
        case .binary(let byteBuffer):
          guard
            let data = Data(byteBuffer: byteBuffer),
            let messageEnvelope = try? self.decoder.decode(Components.Schemas.SeamlessStreamMessage.self, from: data),
            let message = SeamlessBackend.StreamMessage(messageEnvelope)
          else { continue }
          self.logger.debug("Output", metadata: ["message": .string("\(message)")])
          switch message {
          case .user(let userMessage):
            try await self.outboundConnections.send(userMessage, to: connection.id)
          case .assistant:
            // TODO: Shouldn't happen, needs to be fixed
            ()
          }
        default:
          break
        }
      }
    case .jsonl(let jsonlConnection):
      // We handle the stream as incoming messages emitted by this client
      // The `for try await` loop will suspend until a new message is available
      // Once a message is available, the message is handled before awaiting the next one
      // This implicitly applies "backpressure" to the client, to prevent it from sending too many messages
      // which would've otherwise overwhelmed the server
      for try await message in jsonlConnection.inbound {
        guard let message = SeamlessBackend.StreamMessage(message) else { continue }
        switch message {
        case .user(let userMessage):
          try await self.outboundConnections.send(userMessage, to: connection.id)
        case .assistant:
          // TODO: Shouldn't happen, needs to be fixed
          ()
        }
      }
    }
  }

  public init(
    actorSystem: ClusterSystem,
    schemas: [any SeamlessCore.SeamlessSchema.Type],
    logger: Logger
  ) async {
    self.actorSystem = actorSystem
    self.typeLooker = schemas.reduce(into: [String: any SeamlessCore.SeamlessSchema.Type](), { $0[$1.identifier] = $1 })
    self.logger = logger
    (self.connectionStream, self.connectionContinuation) = AsyncStream<Connection>.makeStream()
    self.outboundConnections = OutboundConnections(logger: logger)
    for schema in schemas {
      self.pools[schema.identifier] = try? await pool(type: schema)
    }
  }

  private func pool(type: any SeamlessCore.SeamlessSchema.Type) async throws -> AnyWorkerPool {
    try await _pool(for: type)
  }

  private func _pool<S: SeamlessCore.SeamlessSchema>(for type: S.Type) async throws -> AnyWorkerPool {
    try await AnyWorkerPool(
      WorkerPool<ResponseWorker<S>>(
        selector: .dynamic(.responseWorker(for: S.self)),
        actorSystem: self.actorSystem
      )
    )
  }
}

extension SessionService {

  public func addWSConnectionFor(
    request: SessionService.Connection.RequestParameter,
    inbound: WebSocketInboundStream
  ) async throws -> Connection.WebSocketConnection.OutputStream {
    guard let type = self.typeLooker[request.schemaID] else {
      throw SeamlessError.schemaUnavailable
    }

    let outbound = Connection.WebSocketConnection.OutputStream()
    let connection = try await self.openConnection(
      of: type,
      actorSystem: self.actorSystem,
      sessionId: request.sessionId,
      response: { [weak outbound] messages in
        let data = try self.encoder.encode(messages)
        await outbound?.send(.frame(.binary(ByteBuffer(data: data))))
      }
    )
    let stream = Connection.websocket(
      .init(
        requestParameter: request,
        connection: connection,
        inbound: inbound,
        outbound: outbound
      )
    )
    self.connectionContinuation.yield(stream)
    return outbound
  }

  public func sync(messages: [Components.Schemas.SeamlessStreamMessage], transcript: String?, for request: SessionService.Connection.RequestParameter) async throws {
    let backendMessages = messages.compactMap { SeamlessBackend.StreamMessage($0) }
    let decodedTranscript =
      transcript
      .flatMap { Data(base64Encoded: $0) }
      .flatMap { try? self.decoder.decode(Transcript.self, from: $0) }
    try await self.outboundConnections.sync(backendMessages, transcript: decodedTranscript, to: request.id)
  }

  public func addJSONLConnectionFor(
    request: SessionService.Connection.RequestParameter,
    inbound: AsyncThrowingMapSequence<JSONLinesDeserializationSequence<HTTPBody>, Components.Schemas.SeamlessStreamMessage>
  ) async throws -> Connection.JSONLConnection.OutputStream {
    guard let type = self.typeLooker[request.schemaID] else {
      throw SeamlessError.schemaUnavailable
    }

    let outbound = Connection.JSONLConnection.OutputStream()
    let connection = try await self.openConnection(
      of: type,
      actorSystem: self.actorSystem,
      sessionId: request.sessionId,
      response: { [weak outbound] messages in
        let messages = messages.compactMap { try? Components.Schemas.SeamlessStreamMessage($0) }
        for message in messages {
          await outbound?.send(.response(message))
        }
      }
    )
    let stream = Connection.jsonl(
      .init(
        requestParameter: request,
        connection: connection,
        inbound: inbound,
        outbound: outbound
      )
    )
    self.connectionContinuation.yield(stream)
    return outbound
  }

  public func removeJSONLConnectionFor(
    request: SessionService.Connection.RequestParameter
  ) async throws {
    try await self.outboundConnections.remove(connectionWithId: request.id)
  }

  private func openConnection<S: SeamlessCore.SeamlessSchema>(
    of type: S.Type,
    actorSystem: ClusterSystem,
    sessionId: SeamlessBackend.SessionID,
    response: @Sendable @escaping ([SeamlessBackend.StreamMessage]) async throws -> Void
  ) async throws -> SeamlessBackend.AnyConnection {
    try await SeamlessBackend.AnyConnection(
      SeamlessBackend.Connection<S>(
        actorSystem: actorSystem,
        sessionID: sessionId,
        response: response
      )
    )
  }
}

extension Data {
  init?(byteBuffer: ByteBuffer) {
    var buffer = byteBuffer
    guard
      let data = buffer.readData(
        length: buffer.readableBytes,
        byteTransferStrategy: .automatic
      )
    else { return nil }
    self = data
  }
}

extension SessionService.Connection {

  public struct RequestParameter: Hashable, Identifiable, Sendable {
    public var id: String { "\(self.sessionId)_\(self.schemaID)" }
    public let sessionId: String
    public let schemaID: String

    public init(
      sessionId: String,
      schemaID: String
    ) {
      self.sessionId = sessionId
      self.schemaID = schemaID
    }
  }

  public struct JSONLConnection: Identifiable, Sendable {

    public enum Output: Sendable {
      case close(reason: String)
      case response(Components.Schemas.SeamlessStreamMessage)
    }

    typealias InputStream = AsyncThrowingMapSequence<JSONLinesDeserializationSequence<HTTPBody>, Components.Schemas.SeamlessStreamMessage>
    public typealias OutputStream = AsyncChannel<Output>

    public var id: String { self.requestParameter.id }
    let requestParameter: RequestParameter

    let connection: SeamlessBackend.AnyConnection

    let inbound: InputStream
    let outbound: OutputStream

    func send(message: SeamlessBackend.StreamMessage.UserMessage) async throws {
      try await self.connection.send(message: message)
    }

    func sync(messages: [SeamlessBackend.StreamMessage], transcript: Transcript?) async throws {
      try await self.connection.sync(messages: messages, transcript: transcript)
    }
  }

  public struct WebSocketConnection: Identifiable, Sendable {
    public enum Output: Sendable {
      case close(reason: String)
      case frame(WebSocketOutboundWriter.OutboundFrame)
    }
    public typealias OutputStream = AsyncChannel<Output>

    public var id: String { self.requestParameter.id }
    let requestParameter: RequestParameter

    let connection: SeamlessBackend.AnyConnection

    let inbound: WebSocketInboundStream
    let outbound: OutputStream

    func send(message: SeamlessBackend.StreamMessage.UserMessage) async throws {
      try await self.connection.send(message: message)
    }

    func sync(messages: [SeamlessBackend.StreamMessage], transcript: Transcript?) async throws {
      try await self.connection.sync(messages: messages, transcript: transcript)
    }
  }
}

//fileprivate extension SeamlessBackend.StreamRequest.Message {
//    init(_ message: ExecuteRequest) {
//        self.conversationID = message.conversationID
//        self.instructions = message.instructions
//        self.prompt = message.prompt
//    }
//}

extension SeamlessBackend.StreamMessage {
  fileprivate init?(
    _ message: Components.Schemas.SeamlessStreamMessage
  ) {
    switch message {
    case .user(let wrapper):
      let userMessage: SeamlessBackend.StreamMessage.UserMessage? =
        switch wrapper.message {
        case .request(let prompt):
          .request(prompt: prompt.prompt, createdAt: wrapper.createdAt)
        case .connected:
          .connected(wrapper.createdAt)
        case .disconnected:
          .disconnected(wrapper.createdAt)
        case .heartbeat:
          nil
        }
      guard let userMessage else { return nil }
      self = .user(userMessage)
    case .assistant(let wrapper):
      let assistantMessage: SeamlessBackend.StreamMessage.AssistantMessage? = {
        switch wrapper.message {
        case .partial(let message):
          guard let data = Data(base64Encoded: message.data) else { return nil }
          return .partial(data, createdAt: wrapper.createdAt, isRemote: wrapper.isRemote ?? false)
        case .completed(let message):
          guard let data = Data(base64Encoded: message.data) else { return nil }
          return .completed(data, createdAt: wrapper.createdAt, isRemote: wrapper.isRemote ?? false)
        case .error(let message):
          return .error(message.errorText, createdAt: wrapper.createdAt, isRemote: wrapper.isRemote ?? false)
        case .heartbeat:
          return nil
        case .transcript(let msg):
          return Data(base64Encoded: msg.data).map { SeamlessBackend.StreamMessage.AssistantMessage.transcript($0, createdAt: wrapper.createdAt) }
        }
      }()
      guard let assistantMessage else { return nil }
      self = .assistant(assistantMessage)
    }
  }
}

extension Components.Schemas.SeamlessStreamMessage {
  fileprivate init?(
    _ message: SeamlessBackend.StreamMessage,
  ) throws {
    switch message {
    case .user(let userMessage):
      let userMessage: Components.Schemas.UserMessage =
        switch userMessage {
        case .request(let prompt, _):
          .request(.init(_type: .request, prompt: prompt))
        case .connected:
          .connected(.init(_type: .connected))
        case .disconnected:
          .disconnected(.init(_type: .disconnected))
        }
      self = .user(
        .init(
          role: .user,
          createdAt: message.createdAt,
          message: userMessage
        )
      )
    case .assistant(let assistantMessage):
      let isRemote = assistantMessage.isRemote
      let assistantMessage: Components.Schemas.AssistantMessage = {
        switch assistantMessage {
        case .partial(let message, let createdAt, let isRemote):
          let data = message.base64EncodedString()
          return .partial(.init(_type: .partial, data: data))
        case .completed(let message, let createdAt, let isRemote):
          let data = message.base64EncodedString()
          return .completed(.init(_type: .completed, data: data))
        case .error(let text, let createdAt, let isRemote):
          return .error(.init(_type: .error, errorText: text))
        case .heartbeat:
          return .heartbeat(.init(_type: .heartbeat))
        case .transcript(let data, _):
          return .transcript(.init(_type: .transcript, data: data.base64EncodedString()))
        }
      }()
      self = .assistant(
        .init(
          role: .assistant,
          createdAt: message.createdAt,
          isRemote: isRemote,
          message: assistantMessage
        )
      )
    }
  }
}

struct AnyWorkerPool: Identifiable, Hashable, Sendable {

  var id: String
  private let _submit: @Sendable (String) async throws -> (Operations.execute.Output)

  init<S: SeamlessCore.SeamlessSchema>(
    _ pool: WorkerPool<ResponseWorker<S>>
  ) async throws {
    self.id = S.identifier
    let encoder = JSONEncoder()
    self._submit = {
      let result = try await pool.submit(work: $0)
      let data = try encoder.encode(result)
      return .ok(.init(body: .json(.init(payload: data.base64EncodedString()))))
    }
  }

  func sumbit(_ prompt: String) async throws -> Operations.execute.Output {
    try await self._submit(prompt)
  }

  static func == (lhs: AnyWorkerPool, rhs: AnyWorkerPool) -> Bool {
    lhs.id == rhs.id
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(self.id)
  }
}
