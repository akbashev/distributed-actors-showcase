import DistributedCluster
import Foundation

public distributed actor CalculationWorker: DistributedWorker {
  public typealias ActorSystem = ClusterSystem
  public typealias WorkItem = CalculationWork
  public typealias WorkResult = CalculationRecord

  private let nodeLabel: String

  public init(
    actorSystem: ClusterSystem,
    nodeLabel: String
  ) async {
    self.actorSystem = actorSystem
    self.nodeLabel = nodeLabel
    await self.actorSystem.receptionist.checkIn(self, with: .calculatorWorkers)
  }

  distributed public func submit(work: WorkItem) async throws -> WorkResult {
    let outcome: CalculationOutcome

    do {
      outcome = .success(try work.evaluate())
    } catch let error as CalculatorError {
      switch error {
      case .divisionByZero:
        outcome = .failure("Division by zero is not allowed.")
      }
    } catch {
      outcome = .failure("Internal calculation error.")
    }

    return .init(
      id: UUID(),
      timestamp: Date(),
      lhs: work.lhs,
      rhs: work.rhs,
      operation: work.operation,
      workerNode: self.nodeLabel,
      workerID: self.id.description,
      outcome: outcome
    )
  }
}

extension DistributedReception.Key where Guest == CalculationWorker {
  public static var calculatorWorkers: Self { .init(id: "calculator-workers") }
}
