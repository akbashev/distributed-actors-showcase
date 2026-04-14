import AsyncAlgorithms
import Foundation
import OpenAPIRuntime
import SeamlessAPI
import SeamlessCore

public actor SeamlessRemote {

  private let client: any APIProtocol
  private var connections: [String: AnyContinuation] = [:]
  private static let heartbeatInterval: Duration = .seconds(10)
  private let heartbeatSequence = AsyncTimerSequence(
    interval: SeamlessRemote.heartbeatInterval,
    clock: .continuous
  )

  public init(client: any APIProtocol) {
    self.client = client
  }

  public func connect<S: SeamlessCore.SeamlessSchema>(
    sessionId: String
  ) async throws -> AsyncThrowingStream<SeamlessMessage<S>, Error> {
    let (bodyStream, bodyContinuation) = AsyncThrowingStream<Components.Schemas.SeamlessStreamMessage, Error>.makeStream()
    self.connections[sessionId] = AnyContinuation(bodyContinuation)
    let input = Operations.connectConversation.Input(
      path: .init(sessionID: sessionId),
      headers: .init(schemaID: S.identifier),
      body: .application_jsonl(
        .init(
          bodyStream.asEncodedJSONLines(),
          length: .unknown,
          iterationBehavior: .single
        )
      )
    )
    let response = try await client.connectConversation(input)
    if heartbeatTask == .none {
      self.heartbeat()
    }
    return AsyncThrowingStream { continuation in
      let task = Task {
        do {
          switch response {
          case .ok(let ok):
            switch ok.body {
            case .application_jsonl(let body):
              for try await line in body.asDecodedJSONLines(of: Components.Schemas.SeamlessStreamMessage.self) {
                if let message = try? SeamlessMessage<S>(line) {
                  continuation.yield(message)
                }
              }
            }
          case .undocumented(let statusCode, _):
            throw SeamlessError.executionFailed("Remote connection failed with HTTP \(statusCode)")
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in
        task.cancel()
      }
    }
  }

  public func send<S: SeamlessCore.SeamlessSchema>(
    message: SeamlessMessage<S>,
    to sessionId: String
  ) async throws {
    let apiMessage = try Components.Schemas.SeamlessStreamMessage(message)
    self.connections[sessionId]?.yield(apiMessage)
  }

  public func sync<S: SeamlessCore.SeamlessSchema>(
    sessionId: String,
    messages: [SeamlessMessage<S>],
    transcript: Data? = nil
  ) async throws {
    let streamMessages = try messages.map { try Components.Schemas.SeamlessStreamMessage($0) }
    let input = Operations.sync.Input(
      path: .init(sessionID: sessionId),
      headers: .init(schemaID: S.identifier),
      body: .json(.init(messages: streamMessages, transcript: transcript.map { $0.base64EncodedString() }))
    )
    let response = try await client.sync(input)
    if case .undocumented(let statusCode, _) = response {
      throw SeamlessError.executionFailed("Remote sync failed with HTTP \(statusCode)")
    }
  }

  public func disconnect(sessionId: String) async {
    self.connections.removeValue(forKey: sessionId)
  }

  public func respond<S: SeamlessCore.SeamlessSchema>(to prompt: String) async throws -> S {
    let input = Operations.execute.Input(
      body: .json(.init(schemaID: S.identifier, prompt: prompt))
    )
    let response = try await client.execute(input)
    switch response {
    case .ok(let ok):
      switch ok.body {
      case .json(let body):
        guard let data = Data(base64Encoded: body.payload) else {
          throw SeamlessError.executionFailed("Invalid Base64 payload from remote")
        }
        return try JSONDecoder().decode(S.self, from: data)
      }
    case .undocumented(let statusCode, _):
      throw SeamlessError.executionFailed("Remote execution failed with HTTP \(statusCode)")
    }
  }

  private var heartbeatTask: Task<Void, Never>?
  private func heartbeat() {
    self.heartbeatTask = Task {
      for await _ in heartbeatSequence {
        for (info, connection) in self.connections {
          connection.yield(
            Components.Schemas.SeamlessStreamMessage.assistant(
              .init(
                role: .assistant,
                createdAt: Date(),
                message: .heartbeat(.init(_type: .heartbeat))
              )
            )
          )
        }
      }
    }
  }

  deinit {
    self.heartbeatTask?.cancel()
  }
}

struct AnyContinuation: Sendable {
  private let _yield: @Sendable (Any) -> Void
  private let _yieldResult: @Sendable (Result<Any, Error>) -> Void
  private let _finish: @Sendable (Error?) -> Void

  init<T: Sendable>(_ cont: AsyncThrowingStream<T, Error>.Continuation) {
    self._yield = { anyValue in
      guard let value = anyValue as? T else {
        assertionFailure("Type mismatch when yielding to stream continuation")
        return
      }
      cont.yield(value)
    }
    self._yieldResult = { result in
      switch result {
      case .success(let anyValue):
        guard let value = anyValue as? T else {
          assertionFailure("Type mismatch when yielding result to stream continuation")
          return
        }
        cont.yield(value)
      case .failure(let error):
        cont.finish(throwing: error)
      }
    }
    self._finish = { error in
      if let error {
        cont.finish(throwing: error)
      } else {
        cont.finish()
      }
    }
  }

  func yield(_ anyValue: Any) { _yield(anyValue) }
  func yield(with result: Result<Any, Error>) { _yieldResult(result) }
  func finish(throwing error: Error? = nil) { _finish(error) }
}
