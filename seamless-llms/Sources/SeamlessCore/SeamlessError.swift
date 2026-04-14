import Foundation

public enum SeamlessError: Error, Codable, Sendable {
  case connectionCantBeEstablished
  case sessionNotFound
  case executionFailed(String)
  case schemaUnavailable
}
