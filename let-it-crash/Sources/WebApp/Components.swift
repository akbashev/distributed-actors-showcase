import Backend
import Elementary
import Foundation

public struct ClientSelectionPage: HTML, Sendable {
  public typealias Tag = Never
  public init() {}

  public var body: some HTML {
    html {
      head {
        Elementary.title { "Select Client" }
        link(.rel(.stylesheet), .href("/style.css"))
      }
      Elementary.body {
        div(.class("container")) {
          div(.class("card")) {
            h1 { "Calculator" }
            p { "Enter your Client ID to start calculating." }
            form(.action("/"), .method(.get)) {
              div(.class("form-group")) {
                label { "Client ID" }
                input(.type(.number), .name("clientId"), .placeholder("e.g. 1"))
              }
              button(.type(.submit)) { "Open Calculator" }
            }
          }
        }
      }
    }
  }
}

public struct CalculatorPage: HTML, Sendable {
  public typealias Tag = Never
  let clientId: Int
  let history: [CalculationRecord]

  public init(clientId: Int, history: [CalculationRecord]) {
    self.clientId = clientId
    self.history = history
  }

  public var body: some HTML {
    html {
      head {
        Elementary.title { "Calculator - Client \(clientId)" }
        link(.rel(.stylesheet), .href("/style.css"))
      }
      Elementary.body {
        div(.class("container")) {
          div(.class("header-row")) {
            h1 { "Calculator" }
            a(.href("/"), .class("btn-secondary")) { "Switch Client" }
          }

          p { "Connected as Client \(clientId)" }

          div(.class("card")) {
            h2 { "New Calculation" }
            form(.action("/calculate"), .method(.post)) {
              input(.type(.hidden), .name("clientId"), .value("\(clientId)"))

              div(.class("expression-row")) {
                input(.type(.text), .name("lhs"), .placeholder("LHS"))
                select(.name("op")) {
                  option(.value("add")) { "+" }
                  option(.value("sub")) { "−" }
                  option(.value("mul")) { "×" }
                  option(.value("div")) { "÷" }
                }
                input(.type(.text), .name("rhs"), .placeholder("RHS"))
              }
              button(.type(.submit)) { "Calculate" }
            }
          }

          div(.class("card")) {
            h2 { "History" }
            if history.isEmpty {
              p { "No calculations recorded yet." }
            } else {
              div(.class("history-container")) {
                table {
                  thead {
                    tr {
                      th { "Time" }
                      th { "Expression" }
                      th { "Result" }
                      th { "Worker" }
                    }
                  }
                  tbody {
                    for record in history {
                      tr {
                        td {
                          span(.class("timestamp")) {
                            record.timestamp.formatted(date: .omitted, time: .shortened)
                          }
                        }
                        td { "\(record.lhs) \(record.operation.rawValue) \(record.rhs)" }
                        td {
                          switch record.outcome {
                          case .success(let value):
                            span(.class("success")) { "\(value)" }
                          case .failure(let error):
                            span(.class("error")) { error }
                          }
                        }
                        td { code { record.workerNode } }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
