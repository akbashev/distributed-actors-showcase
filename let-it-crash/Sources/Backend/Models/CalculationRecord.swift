import Foundation

public struct CalculationRecord: Codable, Sendable {
  public let id: UUID
  public let timestamp: Date
  public let lhs: String
  public let rhs: String
  public let operation: Operation
  public let workerNode: String
  public let workerID: String
  public let outcome: CalculationOutcome

  public init(
    id: UUID,
    timestamp: Date,
    lhs: String,
    rhs: String,
    operation: Operation,
    workerNode: String,
    workerID: String,
    outcome: CalculationOutcome
  ) {
    self.id = id
    self.timestamp = timestamp
    self.lhs = lhs
    self.rhs = rhs
    self.operation = operation
    self.workerNode = workerNode
    self.workerID = workerID
    self.outcome = outcome
  }
}
