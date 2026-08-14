public struct CalculationWork: Codable, Sendable {
  public let lhs: String
  public let rhs: String
  public let operation: Operation

  public init(lhs: String, rhs: String, operation: Operation) {
    self.lhs = lhs
    self.rhs = rhs
    self.operation = operation
  }

  func evaluate() throws -> Int {
    let lhs = Int(self.lhs)!
    let rhs = Int(self.rhs)!
    switch self.operation {
    case .add:
      return lhs + rhs
    case .subtract:
      return lhs - rhs
    case .multiply:
      return lhs * rhs
    case .divide:
      // TODO: Fix, why dividing by zero?!
      //            guard rhs != 0 else { throw CalculatorError.divisionByZero }
      return lhs / rhs
    }
  }
}
