import EventSourcing
import Foundation

/// File-based `EventStore` fallback for running without Postgres: one JSONL
/// file per persistence ID under `~/Library/Application Support`.
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

  public func eventsFor<Event: Codable & Sendable>(id: String, fromSequenceNumber: Int64)
    async throws -> [Event]
  {
    let url = fileURL(for: id)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let data = try Data(contentsOf: url)
    let events =
      try data
      .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
      .map { try decoder.decode(Event.self, from: Data($0)) }
    return Array(events.dropFirst(max(0, Int(fromSequenceNumber - 1))))
  }

  private func fileURL(for id: String) -> URL {
    let safe =
      id
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
    return directory.appendingPathComponent("\(safe).jsonl")
  }
}
