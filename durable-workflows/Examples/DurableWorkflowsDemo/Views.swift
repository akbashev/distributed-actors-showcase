import DurableWorkflows
import Elementary
import ElementaryHTMX
import ElementaryHTMXWS
import Foundation
import TravelBooking

public struct Page<Content: HTML & Sendable>: HTMLDocument, Sendable {
  public let pageContent: Content
  public let username: String?

  public init(pageContent: Content, username: String? = nil) {
    self.pageContent = pageContent
    self.username = username
  }

  public var title: String { "Durable Travel Booking" }

  public var head: some HTML {
    meta(.charset(.utf8))
    meta(.name("viewport"), .content("width=device-width, initial-scale=1"))
    link(.href("/style.css"), .rel(.stylesheet))
    script(.src("https://unpkg.com/htmx.org@2.0.3")) {}
    script(.src("https://unpkg.com/htmx-ext-ws@2.0.1/ws.js")) {}
  }

  public var body: some HTML {
    // THE PERMANENT FIX: The WebSocket connection is global and never swapped.
    div(.id("ws-sink"), .style("display:none;")) {}
    main(
      .class("container"),
      .hx.ext(.ws),
      .hx.target("#ws-sink"),
      .ws.connect(username.map { "/ws?username=\($0)" } ?? "")
    ) {
      header(.style("margin-bottom: 2rem;")) {
        h1 { "Durable Travel Booking" }
        p(.style("opacity: 0.7;")) { "Resilient travel booking saga with event-sourcing and virtual actors." }
      }
      div(.id("main-app")) {
        pageContent
      }
    }
  }
}

public struct UserEntryFragment: HTML, Sendable {
  public init() {}
  public var body: some HTML {
    section(.class("card"), .style("max-width: 500px; margin: 4rem auto; text-align: center;")) {
      h2 { "Welcome Back" }
      p { "Enter your username to access your travel dashboard." }
      form(.action("/dashboard"), .method(.get), .style("margin-top: 2rem;")) {
        div(.style("display: flex; flex-direction: column; gap: 1rem;")) {
          input(
            .type(.text),
            .name("username"),
            .placeholder("Username"),
            .required,
            .style("text-align: center;")
          )
          button(.type(.submit)) { "Enter Dashboard" }
        }
      }
    }
  }
}

public struct BookingButtonFragment: HTML, Sendable {
  public let isDisabled: Bool
  public let oob: Bool

  public init(isDisabled: Bool, oob: Bool = false) {
    self.isDisabled = isDisabled
    self.oob = oob
  }

  public var body: some HTML {
    div(.id("book-btn"), .hx.swapOOB(oob)) {
      if isDisabled {
        button(.type(.submit), .disabled, .style("opacity: 0.5; cursor: not-allowed;")) { "Booking in progress..." }
      } else {
        button(.type(.submit)) { "Book Trip Now" }
      }
    }
  }
}

public struct BalanceFragment: HTML, Sendable {
  public let balance: Int
  public let oob: Bool

  public init(balance: Int, oob: Bool = false) {
    self.balance = balance
    self.oob = oob
  }

  public var body: some HTML {
    div(.id("balance-amount"), .hx.swapOOB(oob)) {
      span { "$\(String(format: "%.2f", Double(balance) / 100.0))" }
    }
  }
}

public struct HotelOptionsFragment: HTML, Sendable {
  public let hotels: [Hotel]
  public init(hotels: [Hotel]) { self.hotels = hotels }

  public var body: some HTML {
    option(.value(""), .selected, .disabled) { "Select a Hotel" }
    ForEach(hotels.enumerated()) { index, hotel in
      option(.value("\(index)")) { "\(hotel.name) ($\(String(format: "%.2f", Double(hotel.costCents)/100.0)))" }
    }
  }
}

public struct DashboardFragment: HTML, Sendable {
  public let username: String
  public let initialBalance: Int
  public let recentWorkflows: [String]
  public let activeWorkflow: (id: String, info: WorkflowStatusInfo)?

  public init(username: String, balance: Int = 0, recentWorkflows: [String] = [], activeWorkflow: (id: String, info: WorkflowStatusInfo)? = nil) {
    self.username = username
    self.initialBalance = balance
    self.recentWorkflows = recentWorkflows
    self.activeWorkflow = activeWorkflow
  }

  public var body: some HTML {
    div {
      div(.class("balance-card")) {
        div {
          div(.style("font-size: 0.9rem; opacity: 0.9;")) { "Available Balance" }
          div(.style("font-size: 2.2rem; font-weight: bold;")) {
            BalanceFragment(balance: initialBalance)
          }
        }
        form(.ws.send) {
          input(.type(.hidden), .name("case"), .value("addMoney"))
          button(.style("background: rgba(255,255,255,0.2); border: 1px solid white; padding: 0.5rem 1rem;")) {
            "Add $500.00"
          }
        }
      }

      section(.class("card")) {
        h2 { "Plan a New Trip" }
        form(.ws.send, .on(.submit, "var b=this.querySelector('[type=submit]');b.disabled=true;b.textContent='Booking in progress\u{2026}';")) {
          input(.type(.hidden), .name("case"), .value("book"))
          div(.style("display: flex; flex-direction: column; gap: 1rem;")) {
            select(
              .name("cityIndex"),
              .required,
              .hx.get("/hotels"),
              .hx.target("#hotel-select"),
              .hx.trigger(.event(.change))
            ) {
              option(.value(""), .selected, .disabled) { "Select a Destination" }
              ForEach(City.top10.enumerated()) { index, city in
                option(.value("\(index)")) { "\(city.name) (Flight: $\(String(format: "%.2f", Double(city.flightCostCents)/100.0)))" }
              }
            }
            select(.id("hotel-select"), .name("hotelIndex"), .required) {
              option(.value(""), .selected, .disabled) { "Choose a city first" }
            }
            BookingButtonFragment(isDisabled: activeWorkflow.map { $0.info.status == .running } ?? false)
          }
        }
      }

      // --- THE UNIFIED TARGET AREA ---
      div(.id("active-workflow-area"), .style("margin-top: 2rem; min-height: 200px;")) {
        if let active = activeWorkflow {
          WorkflowStatusCard(
            id: active.id,
            status: active.info.status.name,
            events: active.info.events,
            result: {
              switch active.info.status {
              case .completed(let data):
                let decoder = JSONDecoder()
                // Note: result might contain actor refs, but we only need basic info here
                return try? decoder.decode(TravelBookingWorkflow.BookingResult.self, from: data)
              default:
                return nil
              }
            }(),
            error: {
              switch active.info.status {
              case .failed(let error): error
              default: .none
              }
            }()
          )
        }
      }

      RecentBookingsFragment(ids: recentWorkflows)

      section(.class("card"), .style("border-color: var(--danger); text-align: center; margin-top: 2rem;")) {
        h2(.style("color: var(--danger)")) { "Durability Test" }
        p { "Crash the server to test Saga persistence and automatic recovery." }
        button(.class("btn-danger"), .hx.post("/crash")) { "💥 Crash Server" }
      }
    }
  }
}

public struct RecentBookingsFragment: HTML, Sendable {
  public let ids: [String]
  public let oob: Bool

  public init(ids: [String], oob: Bool = false) {
    self.ids = ids
    self.oob = oob
  }

  public var body: some HTML {
    section(.class("card"), .id("bookings-list"), .hx.swapOOB(oob)) {
      h3 { "Recent Bookings" }
      div(.style("display: grid; gap: 0.5rem;")) {
        if ids.isEmpty {
          p { "No bookings yet." }
        } else {
          ForEach(ids) { id in
            div(.style("display: flex; justify-content: space-between; align-items: center; padding: 0.75rem; border: 1px solid var(--line); border-radius: 10px; background: var(--bg);")) {
              code(.style("font-size: 0.8rem;")) { id }
              button(
                .hx.get("/status/\(id)"),
                .hx.target("#active-workflow-area"),
                .hx.swap(.innerHTML)
              ) { "View Status" }
            }
          }
        }
      }
    }
  }
}

public struct WorkflowStatusCard: HTML, Sendable {
  public let id: String
  public let status: String
  public let events: [WorkflowEvent]
  public let result: TravelBookingWorkflow.BookingResult?
  public let error: String?

  public init(id: String, status: String, events: [WorkflowEvent], result: TravelBookingWorkflow.BookingResult?, error: String?) {
    self.id = id
    self.status = status
    self.events = events
    self.result = result
    self.error = error
  }

  public var body: some HTML {
    div(.class("card")) {
      div(.style("display: flex; justify-content: space-between; align-items: start; margin-bottom: 1rem;")) {
        div {
          h2(.style("margin: 0;")) { "Booking Detail" }
          code(.style("opacity: 0.6; font-size: 0.8rem;")) { id }
        }
        span(.class("badge \(statusClass)")) { status }
      }

      if let res = result {
        div(.style("background: #f0fdf4; border: 1px solid #bbf7d0; padding: 1rem; border-radius: 10px; margin-bottom: 1.5rem;")) {
          h4(.style("margin: 0 0 0.5rem 0; color: #166534;")) { res.status == "Confirmed" ? "Booking Confirmed" : "Booking \(res.status.capitalized)" }
          p(.style("margin: 0; font-size: 0.95rem;")) { res.message }

          hr(.style("margin: 1rem 0; opacity: 0.1;"))

          div(.style("display: grid; gap: 0.25rem; font-size: 0.9rem;")) {
            div(.style("display: flex; justify-content: space-between;")) {
              span { "Flight Cost:" }
              span { "$\(String(format: "%.2f", Double(res.flightCostCents)/100.0))" }
            }
            div(.style("display: flex; justify-content: space-between;")) {
              span { "Hotel Cost:" }
              span { "$\(String(format: "%.2f", Double(res.hotelCostCents)/100.0))" }
            }
            if res.totalRefundedCents > 0 {
              div(.style("display: flex; justify-content: space-between; margin-top: 0.5rem; color: var(--danger); font-weight: bold;")) {
                span { "Total Refunded:" }
                span { "$\(String(format: "%.2f", Double(res.totalRefundedCents)/100.0))" }
              }
            } else {
              div(.style("display: flex; justify-content: space-between; margin-top: 0.5rem; font-weight: bold;")) {
                span { "Total Charged:" }
                span { "$\(String(format: "%.2f", Double(res.flightCostCents + res.hotelCostCents)/100.0))" }
              }
            }
          }
        }
      }

      if let err = error {
        div(.style("background: #fef2f2; border: 1px solid #fee2e2; padding: 1rem; border-radius: 10px; margin-bottom: 1.5rem; color: #991b1b;")) {
          h4(.style("margin: 0 0 0.5rem 0;")) { "Execution Error" }
          p(.style("margin: 0; font-size: 0.95rem;")) { err }
        }
      }

      if result == nil && error == nil && status.lowercased() != "completed" && status.lowercased() != "failed" && status.lowercased() != "cancelled" {
        div(.style("margin-bottom: 1.5rem; padding: 1rem; background: var(--bg); border-radius: 10px;")) {
          h4(.style("margin: 0 0 0.8rem 0;")) { "Actions" }
          form(.ws.send) {
            input(.type(.hidden), .name("case"), .value("abort"))
            input(.type(.hidden), .name("workflowId"), .value(id))
            button(.class("btn-danger"), .style("width: 100%;")) { "🛑 Abort Booking" }
          }
        }
      }

      h3 { "Execution History" }
      div(.class("history-list")) {
        if events.isEmpty {
          p { "Waiting for events..." }
        } else {
          ForEach(events.reversed()) { event in
            div(.class("history-item")) {
              renderEvent(event)
            }
          }
        }
      }
    }
  }

  private var statusClass: String {
    switch status.lowercased() {
    case "completed": return "badge-success"
    case "failed": return "badge-danger"
    case "running": return "badge-info"
    case "cancelled": return "badge-warning"
    default: return "badge-info"
    }
  }

  @HTMLBuilder
  private func renderEvent(_ event: WorkflowEvent) -> some HTML {
    switch event {
    case .executionStarted:
      span { "🚀 Workflow started" }
    case .activitySucceeded(_, let name, _):
      span {
        "✅ Activity Success: "
        strong { name }
      }
    case .activityFailed(_, let name, let fail):
      span(.style("color: var(--danger)")) {
        "❌ Activity Failed: "
        strong { name }
        " - \(fail.message)"
      }
    case .executionCompleted(_):
      span(.style("color: var(--success)")) { "🏁 Saga Completed" }
    case .executionCancelled:
      span(.style("color: var(--success)")) { "🛑 Cancellation requested" }
    case .executionFailed(let msg):
      span(.style("color: var(--danger)")) { "💥 Fatal Error: \(msg)" }
    }
  }
}

public struct WorkflowStatusFragment: HTML, Sendable {
  public let id: String
  public let status: String
  public let events: [WorkflowEvent]
  public let result: TravelBookingWorkflow.BookingResult?
  public let error: String?
  public let oob: Bool

  public init(id: String, status: String, events: [WorkflowEvent], result: TravelBookingWorkflow.BookingResult?, error: String?, oob: Bool = false) {
    self.id = id
    self.status = status
    self.events = events
    self.result = result
    self.error = error
    self.oob = oob
  }

  public var body: some HTML {
    div(.id("active-workflow-area"), .hx.swapOOB(oob)) {
      WorkflowStatusCard(id: id, status: status, events: events, result: result, error: error)
    }
  }
}
