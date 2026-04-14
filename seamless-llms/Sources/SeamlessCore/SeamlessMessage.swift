import Foundation
import FoundationModels

public enum SeamlessMessage<S: SeamlessCore.SeamlessSchema>: Sendable, Codable {
  case user(UserMessage)
  case assistant(AssistantMessage)

  public enum UserMessage: Sendable, Codable {
    case prompt(text: String, createdAt: Date)
  }

  public enum AssistantMessage: Sendable, Codable {
    case partial(data: S.PartiallyGenerated, createdAt: Date, isRemote: Bool)
    case completed(data: S, createdAt: Date, isRemote: Bool)
    case error(text: String, createdAt: Date, isRemote: Bool)
    case hearbeat(Date)
    case transcript(Data, createdAt: Date)
  }

  public var id: Date {
    switch self {
    case .user(let userMessage):
      switch userMessage {
      case .prompt(_, let createdAt):
        createdAt
      }
    case .assistant(let assistantMessage):
      switch assistantMessage {
      case .partial(_, let createdAt, _): createdAt
      case .completed(_, let createdAt, _): createdAt
      case .error(_, let createdAt, _): createdAt
      case .hearbeat(let createdAt): createdAt
      case .transcript(_, let createdAt): createdAt
      }
    }
  }
}
