import Foundation
import FoundationModels
import SeamlessCore

extension SeamlessBackend {
  public enum StoreEvent: Codable, Sendable {
    case message(StreamMessage)
    case transcript(id: String, Transcript)
  }
}
