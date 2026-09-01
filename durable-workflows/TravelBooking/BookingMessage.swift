import DurableWorkflows
import Foundation

public enum BookingMessage: Sendable, Identifiable {
  public enum UserAction: Sendable, Codable {
    case join
    case disconnect
    case addMoney
    case abort(workflowId: String)
    case login(username: String)
    case book(cityIndex: Int, hotelIndex: Int)
  }

  public enum SystemUpdate: Sendable, Codable {
    case balanceUpdated(balanceCents: Int)
    case workflowUpdated(id: String, info: WorkflowStatusInfo)
    case workflowListUpdated(ids: [String])
    case error(message: String)
  }

  case user(UserAction)
  case system(SystemUpdate)

  public var id: String {
    UUID().uuidString
  }
}
