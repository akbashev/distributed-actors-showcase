import AsyncAlgorithms
import Foundation
import FoundationModels
import OpenAPIURLSession
import SeamlessCore

public actor SeamlessClient {

  private enum Engine {
    case local(SeamlessEngine)
    case localAndRemote(SeamlessEngine, SeamlessRemote)
    case remote(SeamlessRemote)
  }

  public struct Configuration {
    public enum ExecutionTarget {
      case local
      case localAndRemote(URL)
      case remote(URL)
    }

    public let target: ExecutionTarget

    public init(target: ExecutionTarget) {
      self.target = target
    }
  }

  private let complexityCheckerSession: LanguageModelSession
  private let engine: Engine
  private var cache: [String: [AnySeamlessMessage]] = [:]

  public init(
    configuration: Configuration
  ) throws {
    switch configuration.target {
    case .local:
      self.engine = .local(try SeamlessEngine())
    case .localAndRemote(let remoteBaseURL):
      let client = Client(
        serverURL: remoteBaseURL,
        transport: URLSessionTransport()
      )
      self.engine = .localAndRemote(
        try SeamlessEngine(),
        SeamlessRemote(client: client)
      )
    case .remote(let remoteBaseURL):
      let client = Client(
        serverURL: remoteBaseURL,
        transport: URLSessionTransport()
      )
      self.engine = .remote(
        SeamlessRemote(
          client: client
        )
      )
    }
    let instructions = """
      Analyze the complexity of the user input.
      If it requires multi-step logic, complex reasoning, or coding, classify it as 'hard'.
      If it is a simple greeting, basic question, or single-step command, classify it as 'easy'.
      """
    self.complexityCheckerSession = LanguageModelSession(instructions: instructions)
  }

  public func stream<S: SeamlessCore.SeamlessSchema>(
    sessionId: String
  ) async throws -> AsyncThrowingStream<SeamlessMessage<S>, Error> {
    switch self.engine {
    case .local(let local):
      let local: AsyncThrowingStream<SeamlessMessage<S>, Error> = await local.connect(sessionId: sessionId)
      let currentMessages: [SeamlessMessage<S>] = self.cache[sessionId]?.compactMap { $0.get() } ?? []
      return AsyncThrowingStream { continuation in
        for message in currentMessages {
          continuation.yield(message)
        }
        let localTask = Task {
          do {
            for try await value in local {
              continuation.yield(value)
            }
          } catch {
            continuation.finish(throwing: error)
          }
        }
        continuation.onTermination = { _ in
          localTask.cancel()
        }
      }
    case .localAndRemote(let localEngine, let remoteEngine):
      let localStream: AsyncThrowingStream<SeamlessMessage<S>, Error> = await localEngine.connect(sessionId: sessionId)
      do {
        let remoteStream: AsyncThrowingStream<SeamlessMessage<S>, Error> = try await remoteEngine.connect(sessionId: sessionId)
        return AsyncThrowingStream { continuation in
          let remoteTask = Task {
            do {
              for try await value in remoteStream {
                if case .assistant(.transcript(let data, _)) = value {
                  let transcript = try? JSONDecoder().decode(Transcript.self, from: data)
                  if let transcript {
                    await localEngine.updateSession(with: sessionId, transcript: transcript)
                  }
                } else {
                  continuation.yield(value)
                }
              }
            } catch {
              // Swallow remote errors: best-effort
            }
          }
          let localTask = Task {
            do {
              for try await value in localStream {
                continuation.yield(value)
                await updateCache(
                  sessionId: sessionId,
                  with: value
                )
              }
            } catch {
              continuation.finish(throwing: error)
            }
          }
          continuation.onTermination = { _ in
            localTask.cancel()
            remoteTask.cancel()
          }
        }
      } catch {
        return localStream
      }
    case .remote(let remote):
      return try await remote.connect(sessionId: sessionId)
    }
  }

  private func updateCache<S: SeamlessCore.SeamlessSchema>(
    sessionId: String,
    with message: SeamlessMessage<S>
  ) async {
    switch self.engine {
    case .local(let seamlessEngine):
      break
    case .localAndRemote(let localEngine, let remote):
      self.cache[sessionId, default: []].append(AnySeamlessMessage(message))
      var messagesToSend: [SeamlessMessage<S>] = []
      var transcriptToSync: Data? = nil
      switch message {
      case .user(let userMessage):
        messagesToSend.append(.user(userMessage))
      case .assistant(let assistantMessage):
        switch assistantMessage {
        case .partial, .hearbeat: ()
        case .error, .completed:
          messagesToSend.append(.assistant(assistantMessage))
          if let transcript = await localEngine.transcript(for: sessionId) {
            transcriptToSync = try? JSONEncoder().encode(transcript)
          }
        case .transcript: ()
        }
      }
      do {
        try await remote.sync(
          sessionId: sessionId,
          messages: messagesToSend,
          transcript: transcriptToSync
        )
      } catch {
        // TODO: What to do?!
      }
      self.cache.removeValue(forKey: sessionId)
    case .remote(let remote):
      break
    }
  }

  public func send<S: SeamlessCore.SeamlessSchema>(
    _ type: S.Type,
    sessionId: String,
    inputText: String
  ) async throws {
    let message = SeamlessMessage<S>.UserMessage.prompt(
      text: inputText,
      createdAt: Date()
    )
    switch self.engine {
    case .local(let local):
      try await local.send(message: message, to: sessionId)
    case .localAndRemote(let local, let remote):
      let complexity = await assessComplexity(of: inputText)
      switch complexity {
      case .easy:
        self.cache[sessionId, default: []].append(AnySeamlessMessage(.user(message)))
        try await local.send(
          message: message,
          to: sessionId
        )
        await updateCache(
          sessionId: sessionId,
          with: .user(message)
        )
      case .hard:
        do {
          try await remote.send(
            message: .user(message),
            to: sessionId
          )
        } catch {
          try await local.send(
            message: message,
            to: sessionId
          )
          await updateCache(
            sessionId: sessionId,
            with: .user(message)
          )
        }
      }
    case .remote(let remote):
      try await remote.send(
        message: .user(message),
        to: sessionId
      )
    }
  }

  public func disconnect(sessionId: String) async {
    switch self.engine {
    case .local(let local):
      await local.disconnect(sessionId: sessionId)
    case .localAndRemote(let local, let remote):
      await local.disconnect(sessionId: sessionId)
      await remote.disconnect(sessionId: sessionId)
    case .remote(let remote):
      await remote.disconnect(sessionId: sessionId)
    }
  }

  public func respond<S: SeamlessCore.SeamlessSchema>(to prompt: String) async throws -> S {
    switch self.engine {
    case .local(let local):
      return try await local.respond(to: prompt)
    case .localAndRemote(let local, let remote):
      let complexity = await assessComplexity(of: prompt)
      switch complexity {
      case .easy:
        return try await local.respond(to: prompt)
      case .hard:
        do {
          return try await remote.respond(to: prompt)
        } catch {
          return try await local.respond(to: prompt)
        }
      }
    case .remote(let remote):
      return try await remote.respond(to: prompt)
    }
  }

  /// Uses the complexityCheckerSession to assess prompt difficulty.
  /// Falls back to `.easy` on any error.
  private func assessComplexity(of prompt: String) async -> PromptComplexity {
    do {
      return
        try await complexityCheckerSession
        .respond(
          to: prompt,
          generating: PromptComplexity.self
        ).content
    } catch {
      print("Complexity assessment failed: \(error). Defaulting to .easy")
      return .easy
    }
  }
}

@Generable
private enum PromptComplexity: String {
  case easy
  case hard
}

private enum ExecutionStrategy {
  case local
  case remote
}

private struct AnySeamlessMessage: Identifiable {
  let base: Any
  let id: Date

  init<S: SeamlessCore.SeamlessSchema>(
    _ message: SeamlessMessage<S>
  ) {
    self.base = message
    self.id = message.id
  }

  func get<S: SeamlessCore.SeamlessSchema>() -> SeamlessMessage<S>? {
    self.base as? SeamlessMessage<S>
  }
}
