import EventSourcing
import Foundation

public actor FileEventStore: EventStore {
  private let directory: URL
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()

  public init(directory: URL) throws {
    self.directory = directory
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  public func persistEvent<Event: Codable & Sendable>(
    _ event: Event,
    id: String,
    sequenceNumber: Int64
  ) async throws {
    var line = try encoder.encode(event)
    line.append(UInt8(ascii: "\n"))
    let url = fileURL(for: id)
    if FileManager.default.fileExists(atPath: url.path) {
      let handle = try FileHandle(forWritingTo: url)
      defer { try? handle.close() }
      try handle.seekToEnd()
      handle.write(line)
    } else {
      try line.write(to: url)
    }
  }

  public func eventsFor<Event: Codable & Sendable>(id: String) async throws -> [Event] {
    let url = fileURL(for: id)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url)
    return
      try data
      .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
      .map { try decoder.decode(Event.self, from: Data($0)) }
  }

  private func fileURL(for id: String) -> URL {
    let safe =
      id
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
    return directory.appendingPathComponent("\(safe).jsonl")
  }
}
