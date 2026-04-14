import SeamlessClient
import SwiftUI

public struct ConversationEntryView: View {
  @State private var sessionId: String = ""
  @State private var client: SeamlessClient?

  public init() {}

  public var body: some View {
    let isNavigating = Binding<Bool>(
      get: { self.client != nil },
      set: { value in
        if !value {
          self.client = nil
        }
      }
    )
    NavigationStack {
      VStack(spacing: 20) {
        Text("Join Conversation")
          .font(.largeTitle)
          .fontWeight(.bold)

        TextField("Enter Conversation ID (e.g. test-1)", text: $sessionId)
          .textFieldStyle(.roundedBorder)
          .padding(.horizontal)
          .autocorrectionDisabled()

        Button("Join") {
          if !sessionId.isEmpty {
            self.client = try? SeamlessClient(
              configuration: .init(target: .localAndRemote(URL(string: "http://127.0.0.1:8080")!))
            )
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(sessionId.isEmpty)
        .navigationDestination(isPresented: isNavigating) {
          if let client = self.client {
            ConversationView(
              model: ConversationViewModel(
                client: client,
                conversationID: sessionId
              )
            )
          } else {
            Text("Failed to initialize client")
          }
        }
      }
      .padding()
      .navigationTitle("Seamless Chat")
    }
  }
}
