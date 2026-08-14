import Backend
import Elementary
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdElementary

public struct WebAppRoutes: Sendable {
  let clientLookup: @Sendable (Int) async throws -> Calculator

  public init(clientLookup: @Sendable @escaping (Int) async throws -> Calculator) {
    self.clientLookup = clientLookup
  }

  public func register<Context: RequestContext>(on router: Router<Context>) {
    router.get("/") { request, context -> Response in
      let url = request.uri
      var clientId: Int?

      if let query = url.query {
        let params = query.split(separator: "&").reduce(into: [String: String]()) { dict, pair in
          let parts = pair.split(separator: "=")
          if parts.count == 2 {
            dict[String(parts[0])] = String(parts[1])
          }
        }
        if let idStr = params["clientId"], let id = Int(idStr) {
          clientId = id
        }
      }

      if let clientId {
        context.logger.info("Loading calculator for client \(clientId)")
        let calculator = try await self.clientLookup(clientId)
        let history = try await calculator.history()
        return try HTMLResponse {
          CalculatorPage(clientId: clientId, history: history)
        }.response(from: request, context: context)
      } else {
        return try HTMLResponse {
          ClientSelectionPage()
        }.response(from: request, context: context)
      }
    }

    router.post("/calculate") { request, context -> Response in
      var request = request
      let buffer = try await request.collectBody(upTo: 1024 * 1024)
      let bodyString = String(buffer: buffer)

      let params = bodyString.split(separator: "&").reduce(into: [String: String]()) { dict, pair in
        let parts = pair.split(separator: "=")
        if parts.count == 2 {
          let key = String(parts[0])
          let value = String(parts[1]).removingPercentEncoding ?? String(parts[1])
          dict[key] = value
        }
      }

      guard let clientIdStr = params["clientId"], let clientId = Int(clientIdStr),
        let lhs = params["lhs"], let rhs = params["rhs"], let opStr = params["op"]
      else {
        context.logger.error("Missing or invalid parameters in /calculate request")
        return .init(status: .badRequest)
      }

      context.logger.info("Performing calculation for client \(clientId): \(lhs) \(opStr) \(rhs)")

      let calculator = try await self.clientLookup(clientId)

      let operation: Backend.Operation =
        switch opStr {
        case "add": .add
        case "sub": .subtract
        case "mul": .multiply
        case "div": .divide
        default: .add
        }

      do {
        _ = try await calculator.calculate(.init(lhs: lhs, rhs: rhs, operation: operation))
        context.logger.info("Calculation successful for client \(clientId)")
      } catch {
        context.logger.error("Calculation failed for client \(clientId): \(error)")
      }

      return Response(
        status: .seeOther,
        headers: [.location: "/?clientId=\(clientId)"]
      )
    }
  }
}
