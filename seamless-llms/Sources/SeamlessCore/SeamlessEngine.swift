import Foundation
import FoundationModels

public enum SeamlessEngineError: Error, Codable, Sendable {
  case modelUnavailable
}

public actor SeamlessEngine {

  private var sessions: [String: LanguageModelSession] = [:]
  private var continuations: [String: AnyContinuation] = [:]
  private var tasks: [String: Task<Void, Never>] = [:]
  private let isRemote: Bool

  public func transcript(for sessionId: String) -> Transcript? {
    self.sessions[sessionId]?.transcript
  }

  public init(isRemote: Bool = false) throws {
    guard SystemLanguageModel.default.availability == .available else {
      throw SeamlessEngineError.modelUnavailable
    }
    self.isRemote = isRemote
  }

  public func updateSession(with id: String, transcript: Transcript) {
    guard
      let session = self.sessions[id],
      session.transcript != transcript
    else { return }
    let newSession = LanguageModelSession(transcript: transcript)
    newSession.prewarm()
    self.sessions[id] = newSession
  }

  public func connect<S: SeamlessCore.SeamlessSchema>(
    sessionId: String
  ) async -> AsyncThrowingStream<SeamlessMessage<S>, Error> {
    let (stream, continuation) = AsyncThrowingStream<SeamlessMessage<S>, Error>.makeStream()
    self.continuations[sessionId] = AnyContinuation(continuation)
    continuation.onTermination = { _ in
      Task { await self.removeContinuation(for: sessionId) }
    }
    return stream
  }

  private func removeContinuation(for key: String) {
    self.continuations.removeValue(forKey: key)
  }

  public func send<S: SeamlessCore.SeamlessSchema>(
    message: SeamlessMessage<S>.UserMessage,
    to sessionId: String
  ) {
    self.tasks[sessionId] = Task {
      switch message {
      case .prompt(let text, let createdAt):
        guard let continuation = self.continuations[sessionId] else { return }
        continuation.yield(
          SeamlessMessage<S>.user(
            .prompt(
              text: text,
              createdAt: createdAt
            )
          )
        )
        let session = self.sessions[sessionId, default: LanguageModelSession(instructions: S.instructions)]
        self.sessions[sessionId] = session
        var stream = session.streamResponse(to: text, generating: S.self)
        var generated = false
        var attempts = 3
        repeat {
          do {
            var finalOutput: GeneratedContent?
            for try await event in stream {
              finalOutput = event.rawContent
              continuation.yield(
                SeamlessMessage<S>.assistant(
                  .partial(
                    data: event.content,
                    createdAt: Date(),
                    isRemote: self.isRemote
                  )
                )
              )
            }
            if let finalOutput, let data = try? S(finalOutput) {
              continuation.yield(
                SeamlessMessage<S>.assistant(
                  .completed(
                    data: data,
                    createdAt: Date(),
                    isRemote: self.isRemote
                  )
                )
              )
            }
            generated = true
          } catch LanguageModelSession.GenerationError.exceededContextWindowSize where attempts > 0 {
            let session = session.pruned
            stream = session.streamResponse(to: text, generating: S.self)
            self.sessions[sessionId] = session
            attempts -= 1
          } catch {
            continuation.finish(throwing: error)
            return
          }
        } while !generated
      }
    }
  }

  public func respond<S: SeamlessCore.SeamlessSchema>(to prompt: String) async throws -> S {
    let session = self.sessions[S.identifier, default: LanguageModelSession(instructions: S.instructions)]
    self.sessions[S.identifier] = session

    do {
      return try await session.respond(to: prompt, generating: S.self).content
    } catch LanguageModelSession.GenerationError.exceededContextWindowSize {
      let session = session.pruned
      self.sessions[S.identifier] = session
      return try await session.respond(to: prompt, generating: S.self).content
    } catch {
      throw error
    }
  }

  public func disconnect(sessionId: String) async {
    self.tasks[sessionId]?.cancel()
    self.tasks[sessionId] = nil
    self.continuations[sessionId]?.finish()
    self.continuations[sessionId] = nil
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

extension LanguageModelSession {
  fileprivate var pruned: LanguageModelSession {
    let allEntries = self.transcript
    let condensedEntries = [allEntries.first, allEntries.last].compactMap { $0 }
    let condensedTranscript = Transcript(entries: condensedEntries)
    var newSession = LanguageModelSession(transcript: condensedTranscript)
    newSession.prewarm()
    return newSession
  }
}
