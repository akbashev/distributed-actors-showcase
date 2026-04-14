import SharedModels
import SwiftUI

public struct ConversationView: View {
  @Bindable private var model: ConversationViewModel
  @State private var selectedMessage: ConversationMessage?

  public init(model: ConversationViewModel) {
    self.model = model
  }

  public var body: some View {
    VStack(spacing: 0) {
      messageList
      InputArea(
        inputText: $model.inputText,
        isSending: model.isSending,
        send: model.send
      )
    }
    .onAppear {
      model.start()
    }
    .onDisappear {
      model.stop()
    }
  }

  private var messageList: some View {
    ScrollView {
      LazyVStack(spacing: 12) {
        ForEach(model.messages) { message in
          MessageRow(
            message: message,
            model: model,
            selectedMessage: $selectedMessage
          )
        }
      }
      .padding(16)
    }
    .defaultScrollAnchor(.bottom)
  }
}

struct MessageRow: View {
  let message: ConversationMessage
  let model: ConversationViewModel
  @Binding var selectedMessage: ConversationMessage?

  var body: some View {
    Group {
      if message.isUser {
        UserMessage(message: message.text)
      } else {
        AssistantMessage(
          message: message.text,
          isRemote: message.isRemote
        )
      }
    }
    .onLongPressGesture {
      self.selectedMessage = message
      self.model.generateReaction(for: message)
    }
    .popover(
      isPresented: Binding(
        get: { selectedMessage?.id == message.id },
        set: { if !$0 { selectedMessage = nil } }
      )
    ) {
      ReactionPopoverContent(
        messageID: message.id,
        model: model
      )
      .padding()
      .presentationCompactAdaptation(.popover)
    }
  }
}

struct InputArea: View {
  var inputText: Binding<String>
  let isSending: Bool
  let send: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      TextField("Message", text: inputText)
        .textFieldStyle(.plain)
        .padding(10)
        .background(Color.gray.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onSubmit {
          self.send()
        }

      Button {
        self.send()
      } label: {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 32))
      }
      .disabled(self.isSending)
    }
    .padding(12)
    .background(.thinMaterial)
  }
}

struct UserMessage: View {

  let message: String

  var body: some View {
    HStack {
      Spacer()
      Text(message)
        .foregroundColor(.white)
        .padding([.leading, .trailing], 6)
        .padding([.top, .bottom], 4)
        .background(
          RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
              Color.clear,
              lineWidth: 0
            )
            .background(
              Color.blue
            )
            .clipped()
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
  }
}

struct AssistantMessage: View {

  let message: String
  let isRemote: Bool

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(isRemote ? "Remote" : "Local")
          .font(.footnote)
          .foregroundStyle(Color.secondary)
        Text(message)
          .foregroundColor(.white)
          .padding([.leading, .trailing], 6)
          .padding([.top, .bottom], 4)
          .background(
            RoundedRectangle(cornerRadius: 12)
              .strokeBorder(
                Color.clear,
                lineWidth: 0
              )
              .background(
                Color.green
              )
              .clipped()
          )
          .clipShape(RoundedRectangle(cornerRadius: 12))
      }
      Spacer()
    }
  }
}

struct ReactionPopoverContent: View {
  let messageID: String
  let model: ConversationViewModel

  var body: some View {
    HStack(spacing: 8) {
      if model.isGeneratingReaction(for: messageID) {
        ProgressView()
          .controlSize(.small)
        Text("Analyzing...")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if let reaction = model.reaction(for: messageID) {
        ForEach(reaction.emojis, id: \.self) { emoji in
          Text(emoji)
            .font(.title2)
        }
      } else {
        Text("No reaction")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .fixedSize()
  }
}

extension ConversationMessage {
  var text: String {
    switch self {
    case .user(let userMessage):
      switch userMessage {
      case .prompt(let text, _): text
      }
    case .assistant(let assistantMessage):
      switch assistantMessage {
      case .message(let text, _, _),
        .error(let text, _, _):
        text
      }
    }
  }

  var isRemote: Bool {
    switch self {
    case .user(let userMessage):
      false
    case .assistant(let assistantMessage):
      switch assistantMessage {
      case .error(_, _, let isRemote),
        .message(_, _, let isRemote):
        isRemote
      }
    }
  }

  var isUser: Bool {
    switch self {
    case .user: true
    case .assistant: false
    }
  }
}
