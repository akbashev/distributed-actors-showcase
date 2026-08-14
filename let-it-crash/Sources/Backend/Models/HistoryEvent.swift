import Foundation

public enum HistoryEvent: Codable, Sendable {
  case connected(Date)
  case recorded(CalculationRecord)
}
