import Elementary
import ElementaryHTMX
import ElementaryHTMXWS
import Foundation
import SeamlessClient
import SeamlessCore
import SharedModels

public struct WebAppPage<Content: HTML>: HTMLDocument {
  public var title: String
  private let content: Content

  public init(title: String = "Seamless", @HTMLBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  @HTMLBuilder
  public var head: some HTML {
    meta(.charset(.utf8))
    meta(.name("viewport"), .content("width=device-width, initial-scale=1"))
    script(.src("https://unpkg.com/htmx.org@2.0.1")) {}
    script(.src("https://unpkg.com/htmx-ext-ws@2.0.1/ws.js")) {}
    link(.href("/app.css"), .rel(.stylesheet))
  }

  @HTMLBuilder
  public var body: some HTML {
    header(.class("container app-header")) {
      div {
        h2 { "Seamless" }
        p { "AI-powered Virtual Actors" }
      }
      div(.id("status"), .class("status-pill")) {
        span(.class("status-dot offline"), .init(name: "data-status-dot", value: "")) {}
        span(.init(name: "data-connection-status", value: "")) { "Disconnected" }
      }
    }
    main(.class("container app-main"), .id("main-content")) {
      content
    }
  }
}

public enum WebAppViews {
  public struct EntryView: HTML {
    public init() {}

    public var body: some HTML {
      div(.class("glass-card entry-card")) {
        h3 { "Join Conversation" }
        p(.class("subtle")) { "Enter a conversation ID to start chatting" }
        form(
          .hx.get("/chat"),
          .hx.target("#main-content"),
          .hx.pushURL("true"),
          .class("form-row")
        ) {
          input(
            .type(.text),
            .name("conversationID"),
            .placeholder("e.g. travel-plan-123"),
            .required,
            .autocomplete(.off),
            .autofocus
          )
          button(.type(.submit)) { "Open" }
        }
      }
    }
  }

  public struct ChatView: HTML {
    let conversationID: String

    public init(conversationID: String) {
      self.conversationID = conversationID
    }

    public var body: some HTML {
      div(.class("chat-container")) {
        div(.class("chat-header")) {
          button(
            .hx.get("/"),
            .hx.target("#main-content"),
            .hx.pushURL("true"),
            .class("back-btn")
          ) { "← Back" }
          h4 { conversationID }
        }
        section(
          .class("glass-card chat-shell"),
          .hx.ext(.ws),
          .ws.connect("/api/ws?conversationID=\(conversationID)"),
          .init(name: "hx-on::htmx:wsOpen", value: "document.querySelector('[data-connection-status]').textContent='Connected'; document.querySelector('[data-status-dot]').classList.remove('offline');"),
          .init(name: "hx-on::htmx:wsClose", value: "document.querySelector('[data-connection-status]').textContent='Disconnected'; document.querySelector('[data-status-dot]').classList.add('offline');"),
          .init(name: "hx-on::htmx:wsAfterSend", value: "this.querySelector('form').reset()")
        ) {
          div(.class("message-area")) {
            div(.id("message-list"), .class("message-list")) {
              p(.class("subtle"), .id("empty-message")) { "Waiting for history..." }
            }
            div(.id("assistant-draft")) {}
          }
          form(.ws.send) {
            div(.class("form-row")) {
              input(
                .type(.text),
                .name("message"),
                .placeholder("Type a message..."),
                .autocomplete(.off),
                .required
              )
              button(.type(.submit)) { "Send" }
            }
          }
        }
      }
    }
  }

  public struct MessageUpdate: HTML {
    let message: ConversationMessage
    let isPartial: Bool

    public init(message: ConversationMessage, isPartial: Bool = false) {
      self.message = message
      self.isPartial = isPartial
    }

    @HTMLBuilder
    public var body: some HTML {
      switch message {
      case .user(let user):
        div(.id("empty-message"), .hx.swapOOB(.delete)) {}
        div(.id("message-list"), .hx.swapOOB(.beforeEnd)) {
          div(.class("bubble-wrapper user")) {
            div(.class("bubble")) { user.text }
          }
        }
      case .assistant(let assistant):
        switch assistant {
        case .message(let text, let createdAt, let isRemote):
          if isPartial {
            div(.id("assistant-draft"), .class("bubble-wrapper assistant"), .hx.swapOOB(true)) {
              div(.class("bubble")) {
                span(.class("subtle")) { isRemote ? "Remote: " : "Local: " }
                pre { text }
              }
            }
          } else {
            let safeId = "r\(Int(createdAt.timeIntervalSince1970 * 1000))"
            let reactURL: String = {
              var comps = URLComponents()
              comps.queryItems = [URLQueryItem(name: "message", value: text)]
              return "/api/react?" + (comps.percentEncodedQuery ?? "")
            }()
            div(.id("assistant-draft"), .hx.swapOOB(true)) {}
            div(.id("empty-message"), .hx.swapOOB(.delete)) {}
            div(.id("message-list"), .hx.swapOOB(.beforeEnd)) {
              div(.class("bubble-wrapper assistant")) {
                div(.class("bubble")) {
                  span(.class("subtle")) { isRemote ? "Remote: " : "Local: " }
                  pre { text }
                }
                div(.class("reaction-bar")) {
                  span(.id(safeId)) {}
                  button(
                    .hx.get(reactURL),
                    .hx.target("#\(safeId)"),
                    .init(name: "hx-disabled-elt", value: "this"),
                    .class("react-btn")
                  ) { "Generate emoji" }
                }
              }
            }
            div(.id("status"), .class("status-pill"), .hx.swapOOB(true)) {
              span(.class("status-dot"), .init(name: "data-status-dot", value: "")) {}
              span(.init(name: "data-connection-status", value: "")) { "Connected" }
            }
          }
        case .error(let text, _, _):
          div(.id("status"), .class("status-pill"), .hx.swapOOB(true)) {
            span(.class("status-dot offline"), .init(name: "data-status-dot", value: "")) {}
            span(.init(name: "data-connection-status", value: "")) { text }
          }
        }
      }
    }
  }

  public struct EmojiReactionView: HTML {
    let emojis: [String]

    public init(emojis: [String]) {
      self.emojis = emojis
    }

    public var body: some HTML {
      span(.class("emojis")) { emojis.joined(separator: " ") }
    }
  }
}

extension ConversationMessage.UserMessage {
  var text: String {
    switch self {
    case .prompt(let text, _): text
    }
  }
}

extension ConversationMessage.AssistantMessage {
  var text: String {
    switch self {
    case .message(let text, _, _), .error(let text, _, _): text
    }
  }
}
