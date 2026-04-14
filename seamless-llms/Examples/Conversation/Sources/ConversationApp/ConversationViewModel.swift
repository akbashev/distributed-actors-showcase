import Foundation
import Observation
import SeamlessClient
import SeamlessCore
import SharedModels

@MainActor
@Observable
public final class ConversationViewModel {
  private let conversationID: String
  public var inputText: String = ""

  private let client: SeamlessClient

  public private(set) var reactions: [String: EmojiReaction] = [:]
  private var _messages: [ConversationMessage] = []
  private var lastMessage: ConversationMessage?
  public var messages: [ConversationMessage] { self._messages + [lastMessage].compactMap((\.self)) }
  private var sendingTask: Task<Void, Error>? = nil
  private var streamListenerTask: Task<Void, Error>? = nil
  private var reactionTasks: [String: Task<Void, Error>?] = [:]

  public var isSending: Bool { self.sendingTask != nil }
  public var isListening: Bool { self.streamListenerTask != nil }

  public init(
    client: SeamlessClient,
    conversationID: String
  ) {
    self.client = client
    self.conversationID = conversationID
  }

  public func send() {
    guard !self.isSending else { return }
    let text = self.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    self.sendingTask = Task { [weak self] in
      guard let self else { return }

      defer {
        self.inputText = ""
        self.sendingTask?.cancel()
        self.sendingTask = nil
      }

      try await self.client.send(
        TripPlan.self,
        sessionId: self.conversationID,
        inputText: self.inputText
      )
    }
  }

  public func start() {
    guard !self.isListening else { return }

    self.streamListenerTask = Task { [weak self] in
      guard let self else { return }

      do {
        let updates: AsyncThrowingStream<SeamlessMessage<TripPlan>, any Error> = try await self.client.stream(sessionId: self.conversationID)
        for try await update in updates {
          self.handle(update)
        }
      } catch {
        print(error)
        throw error
      }
    }
  }

  public func stop() {
    self.sendingTask?.cancel()
    self.sendingTask = nil
    self.streamListenerTask?.cancel()
    self.streamListenerTask = nil
    Task {
      await self.client.disconnect(sessionId: self.conversationID)
    }
  }

  public func reaction(for id: String) -> EmojiReaction? {
    self.reactions[id]
  }

  public func isGeneratingReaction(for id: String) -> Bool {
    self.reactionTasks[id] != nil
  }

  public func generateReaction(for message: ConversationMessage) {
    self.reactionTasks[message.id] = Task { [weak self] in
      guard let self else { return }

      defer {
        self.reactionTasks[message.id] = nil
      }
      do {
        let output: EmojiReaction = try await self.client.respond(to: message.text)
        self.reactions[message.id] = output
      } catch is CancellationError {
        // Ignore explicit cancellation.
      }
    }
  }

  private func handle(_ event: SeamlessMessage<TripPlan>) {
    switch event {
    case .user(let userMessage):
      switch userMessage {
      case .prompt(let text, let createdAt):
        self._messages.append(
          .user(
            .prompt(
              text: text,
              createdAt: createdAt
            )
          )
        )
      }
    case .assistant(let assistantMessage):
      switch assistantMessage {
      case .hearbeat, .transcript:
        ()
      case let .partial(data, createdAt, isRemote):
        self.lastMessage =
          .assistant(
            .message(
              text: data.conversationMessage,
              createdAt: createdAt,
              isRemote: isRemote
            )
          )
      case let .completed(data, createdAt, isRemote):
        self.lastMessage = nil
        self._messages.append(
          .assistant(
            .message(
              text: data.conversationMessage,
              createdAt: createdAt,
              isRemote: isRemote
            )
          )
        )
      case let .error(text, createdAt, isRemote):
        self.lastMessage = nil
        self._messages.append(
          .assistant(
            .error(
              text: text,
              createdAt: createdAt,
              isRemote: isRemote
            )
          )
        )
      }
    }
  }
}
