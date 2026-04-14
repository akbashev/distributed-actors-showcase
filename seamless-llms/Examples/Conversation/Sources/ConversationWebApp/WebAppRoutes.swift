import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdElementary
import HummingbirdWebSocket
import SeamlessClient
import SeamlessCore
import SharedModels

public struct WebAppRoutes: Sendable {
  private let client: SeamlessClient

  public init(client: SeamlessClient) {
    self.client = client
  }

  struct WSPayload: Decodable {
    let message: String
  }

  public func register<Context: WebSocketRequestContext>(
    on router: Router<Context>
  ) {
    // Root: Entry Screen
    router.get("/") { request, _ in
      if request.headers[HTTPField.Name("HX-Request")!] != nil {
        return HTMLResponse { WebAppViews.EntryView() }
      }
      return HTMLResponse {
        WebAppPage(title: "Seamless Chat") {
          WebAppViews.EntryView()
        }
      }
    }

    // Chat View
    router.get("/chat") { request, _ in
      let conversationID = request.uri.queryParameters["conversationID"].map(String.init) ?? "test-1"
      if request.headers[HTTPField.Name("HX-Request")!] != nil {
        return HTMLResponse { WebAppViews.ChatView(conversationID: conversationID) }
      }
      return HTMLResponse {
        WebAppPage(title: "Seamless Chat — \(conversationID)") {
          WebAppViews.ChatView(conversationID: conversationID)
        }
      }
    }

    router.get("/api/react") { request, _ in
      let message = request.uri.queryParameters["message"].map(String.init) ?? ""
      let reaction: EmojiReaction = try await self.client.respond(to: message)
      return HTMLResponse { WebAppViews.EmojiReactionView(emojis: reaction.emojis) }
    }

    router.ws("/api/ws") { request, _ in
      let conversationID = request.uri.queryParameters["conversationID"].map(String.init) ?? ""
      guard !conversationID.isEmpty else {
        return .dontUpgrade
      }
      return .upgrade([:])
    } onUpgrade: { inbound, outbound, context in
      let conversationID = context.request.uri.queryParameters["conversationID"].map(String.init) ?? "test-1"

      let stream = try await self.client.stream(sessionId: conversationID) as AsyncThrowingStream<SeamlessCore.SeamlessMessage<TripPlan>, Error>

      try await withThrowingTaskGroup(of: Void.self) { group in
        // Inbound: user messages from browser → SeamlessClient
        group.addTask {
          for try await msg in inbound.messages(maxSize: 1_000_000) {
            let payloadData: Data?
            switch msg {
            case .text(let text): payloadData = text.data(using: .utf8)
            case .binary(let buffer): payloadData = Data(buffer: buffer)
            default: payloadData = nil
            }
            if let data = payloadData,
              let payload = try? JSONDecoder().decode(WSPayload.self, from: data)
            {
              try await self.client.send(
                TripPlan.self,
                sessionId: conversationID,
                inputText: payload.message
              )
            }
          }
        }

        // Outbound: SeamlessClient stream → browser HTML fragments
        group.addTask {
          for try await event in stream {
            guard let msg = ConversationMessage(event) else { continue }
            let isPartial: Bool =
              switch event {
              case .assistant(.partial): true
              default: false
              }
            let html = WebAppViews.MessageUpdate(message: msg, isPartial: isPartial).render()
            try await outbound.write(.text(html))
          }
        }

        // When either task finishes (disconnect or stream end), cancel the other
        try await group.next()
        group.cancelAll()
      }
    }
  }
}
