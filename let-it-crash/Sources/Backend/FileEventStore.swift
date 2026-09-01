import EventSourcing
import Foundation

/// File-based `EventStore` fallback for running without Postgres: one JSONL
/// file per persistence ID under `~/Library/Application Support`.
public actor FileEventStore: EventStore {
  private struct DuplicateEvent: Error {}

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
    let url = fileURL(for: id)
    var line = try encoder.encode(
      EventEnvelope(
        persistenceID: id,
        sequenceNumber: sequenceNumber,
        event: event
      )
    )
    line.append(UInt8(ascii: "\n"))
    if FileManager.default.createFile(atPath: url.path, contents: line) {
      return
    }

    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }
    for try await existingLine in handle.bytes.lines {
      let stored = try decoder.decode(
        EventEnvelope<Event>.self,
        from: Data(existingLine.utf8)
      )
      if stored.sequenceNumber == sequenceNumber {
        throw DuplicateEvent()
      }
    }
    try handle.seekToEnd()
    handle.write(line)
  }

  public func eventStream<Event: Codable & Sendable>(
    id: String,
    fromSequenceNumber: Int64 = 1
  ) async throws -> EventStream<Event> {
    let url = fileURL(for: id)
    let handle = try FileHandle(forReadingFrom: url)
    return handle.bytes.lines
      .map { line in
        try JSONDecoder().decode(
          EventEnvelope<Event>.self,
          from: Data(line.utf8)
        )
      }
      .filter { $0.sequenceNumber >= fromSequenceNumber }
  }

  private func fileURL(for id: String) -> URL {
    let safe =
      id
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: ":", with: "_")
    return directory.appendingPathComponent("\(safe).jsonl")
  }
}
