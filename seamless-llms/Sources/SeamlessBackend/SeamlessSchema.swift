import DistributedCluster
import FoundationModels

public protocol SeamlessSchema: Generable, Sendable, Codable where PartiallyGenerated: Codable {
  static var identifier: String { get }
}
