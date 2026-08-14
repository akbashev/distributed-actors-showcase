public enum CalculationOutcome: Codable, Sendable {
  case success(Int)
  case failure(String)
}
