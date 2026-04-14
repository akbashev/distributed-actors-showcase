import Foundation
import SeamlessCore

public enum ConversationMessage: Sendable, Identifiable {
  public enum UserMessage: Sendable {
    case prompt(text: String, createdAt: Date)
  }
  public enum AssistantMessage: Sendable {
    case error(text: String, createdAt: Date, isRemote: Bool)
    case message(text: String, createdAt: Date, isRemote: Bool)
  }

  case user(UserMessage)
  case assistant(AssistantMessage)

  public var id: String {
    switch self {
    case .user(let userMessage):
      switch userMessage {
      case .prompt(_, let createdAt):
        "user_" + createdAt.ISO8601Format()
      }
    case .assistant(let assistantMessage):
      switch assistantMessage {
      case .error(_, let createdAt, _):
        "assistant_error_" + createdAt.ISO8601Format()
      case .message(_, let createdAt, _):
        "assistant_message_" + createdAt.ISO8601Format()
      }
    }
  }

  var text: String {
    switch self {
    case .user(let userMessage):
      switch userMessage {
      case .prompt(let text, _):
        text
      }
    case .assistant(let assistantMessage):
      switch assistantMessage {
      case .error(let text, _, _):
        text
      case .message(let text, _, _):
        text
      }
    }
  }
}

extension ConversationMessage {
  public init?(_ message: SeamlessMessage<TripPlan>) {
    switch message {
    case .user(let userMessage):
      switch userMessage {
      case .prompt(let text, let createdAt):
        self = .user(.prompt(text: text, createdAt: createdAt))
      }
    case .assistant(let assistantMessage):
      switch assistantMessage {
      case .hearbeat, .transcript:
        return nil
      case let .completed(data, createdAt, isRemote):
        self = .assistant(.message(text: data.conversationMessage, createdAt: createdAt, isRemote: isRemote))
      case let .partial(data, createdAt, isRemote):
        self = .assistant(.message(text: data.conversationMessage, createdAt: createdAt, isRemote: isRemote))
      case let .error(text, createdAt, isRemote):
        self = .assistant(.error(text: text, createdAt: createdAt, isRemote: isRemote))
      }
    }
  }
}

extension TripPlan {
  public var conversationMessage: String {
    var lines: [String] = []
    lines.append("\(self.title) — \(self.destination)")
    lines.append(self.summary)
    for (_, day) in self.days.enumerated() {
      lines.append("\(day.title)")
      for activity in day.activities {
        lines.append("• \(activity.title): \(activity.details)")
      }
    }
    return lines.joined(separator: "\n")
  }
}

extension TripPlan.PartiallyGenerated {
  public var conversationMessage: String {
    var lines: [String] = []
    lines.append([self.title, self.destination].compactMap { $0 }.joined(separator: " — "))
    if let summary {
      lines.append(summary)
    }
    if let days {
      for (_, day) in days.enumerated() {
        if let title = day.title {
          lines.append(title)
        }
        for activity in (day.activities ?? []) {
          lines.append("• " + [activity.title, activity.details].compactMap { $0 }.joined(separator: ": "))
        }
      }
    }
    return lines.joined(separator: "\n")
  }
}
