import Foundation

public struct ExecutionRequest: Codable, Sendable {
  public let id: String
  public let prompt: String
  public let schemaID: String

  public init(id: String, prompt: String, schemaID: String) {
    self.id = id
    self.prompt = prompt
    self.schemaID = schemaID
  }
}
