import FoundationModels

public protocol SeamlessSchema: Generable, Sendable, Codable where PartiallyGenerated: Codable & Sendable {
  static var identifier: String { get }
  static var instructions: String? { get }
}
