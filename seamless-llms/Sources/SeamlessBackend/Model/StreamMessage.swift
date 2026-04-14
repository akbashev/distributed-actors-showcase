import Foundation
import SeamlessAPI

extension SeamlessBackend {
  public enum StreamMessage: Codable, Sendable {
    case user(UserMessage)
    case assistant(AssistantMessage)

    public enum UserMessage: Codable, Sendable {
      case connected(Date)
      case request(prompt: String, createdAt: Date)
      case disconnected(Date)
    }

    public enum AssistantMessage: Codable, Sendable {
      case partial(Data, createdAt: Date, isRemote: Bool)
      case completed(Data, createdAt: Date, isRemote: Bool)
      case error(String, createdAt: Date, isRemote: Bool)
      case heartbeat(createdAt: Date)
      case transcript(Data, createdAt: Date)

      public var isRemote: Bool? {
        switch self {
        case .partial(_, _, let isRemote),
          .completed(_, _, let isRemote),
          .error(_, _, let isRemote):
          return isRemote
        case .heartbeat, .transcript:
          return nil
        }
      }
    }

    public var createdAt: Date {
      switch self {
      case .user(let userMessage):
        switch userMessage {
        case .connected(let date),
          .request(_, let date),
          .disconnected(let date):
          date
        }
      case .assistant(let assistantMessage):
        switch assistantMessage {
        case .partial(_, let date, _),
          .completed(_, let date, _),
          .error(_, let date, _),
          .heartbeat(let date),
          .transcript(_, let date):
          date
        }
      }
    }
  }
}
