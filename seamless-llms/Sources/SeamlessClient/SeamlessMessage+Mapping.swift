import Foundation
import SeamlessAPI
import SeamlessCore

extension SeamlessMessage {
  /// Maps OpenAPI generated components to the core SeamlessMessage model.
  init(_ component: Components.Schemas.SeamlessStreamMessage) throws {
    let decoder = JSONDecoder()
    switch component {
    case .user(let user):
      switch user.message {
      case .request(let request):
        self = .user(.prompt(text: request.prompt, createdAt: user.createdAt))
      default:
        throw SeamlessError.executionFailed("Unsupported user message type")
      }
    case .assistant(let assistant):
      switch assistant.message {
      case .partial(let partial):
        guard let data = Data(base64Encoded: partial.data) else {
          throw SeamlessError.executionFailed("Invalid Base64 in partial message")
        }
        // Scoping to fix generic conflict
        let decoded: S.PartiallyGenerated = try decoder.decode(S.PartiallyGenerated.self, from: data)
        self = .assistant(.partial(data: decoded, createdAt: assistant.createdAt, isRemote: assistant.isRemote ?? true))
      case .completed(let completed):
        guard let data = Data(base64Encoded: completed.data) else {
          throw SeamlessError.executionFailed("Invalid Base64 in completed message")
        }
        let decoded = try decoder.decode(S.self, from: data)
        self = .assistant(.completed(data: decoded, createdAt: assistant.createdAt, isRemote: assistant.isRemote ?? true))
      case .error(let error):
        self = .assistant(.error(text: error.errorText, createdAt: assistant.createdAt, isRemote: assistant.isRemote ?? true))
      case .heartbeat:
        throw SeamlessError.executionFailed("Heartbeat should be filtered out")
      case .transcript(let transcript):
        guard let data = Data(base64Encoded: transcript.data) else {
          throw SeamlessError.executionFailed("Invalid Base64 in transcript message")
        }
        self = .assistant(.transcript(data, createdAt: assistant.createdAt))
      }
    }
  }
}

extension Components.Schemas.SeamlessStreamMessage {
  /// Maps core SeamlessMessage model to OpenAPI generated components.
  init<S: SeamlessCore.SeamlessSchema>(_ message: SeamlessMessage<S>) throws {
    let encoder = JSONEncoder()
    switch message {
    case .user(let userMessage):
      switch userMessage {
      case .prompt(let text, let createdAt):
        self = .user(
          .init(
            role: .user,
            createdAt: createdAt,
            message: .request(.init(_type: .request, prompt: text))
          )
        )
      }
    case .assistant(let assistantMessage):
      switch assistantMessage {
      case .partial(let data, let createdAt, let isRemote):
        self = .assistant(
          .init(
            role: .assistant,
            createdAt: createdAt,
            isRemote: isRemote,
            message: .partial(.init(_type: .partial, data: try encoder.encode(data).base64EncodedString()))
          )
        )
      case .completed(let data, let createdAt, let isRemote):
        self = .assistant(
          .init(
            role: .assistant,
            createdAt: createdAt,
            isRemote: isRemote,
            message: .completed(.init(_type: .completed, data: try encoder.encode(data).base64EncodedString()))
          )
        )
      case .error(let text, let createdAt, let isRemote):
        self = .assistant(
          .init(
            role: .assistant,
            createdAt: createdAt,
            isRemote: isRemote,
            message: .error(.init(_type: .error, errorText: text))
          )
        )
      case .hearbeat(let createdAt):
        self = .assistant(
          .init(
            role: .assistant,
            createdAt: createdAt,
            message: .heartbeat(.init(_type: .heartbeat))
          )
        )
      case .transcript(let data, let createdAt):
        self = .assistant(
          .init(
            role: .assistant,
            createdAt: createdAt,
            message: .transcript(.init(_type: .transcript, data: data.base64EncodedString()))
          )
        )
      }
    }
  }
}
