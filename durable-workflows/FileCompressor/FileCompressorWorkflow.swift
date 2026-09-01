import DurableWorkflows
import Foundation

@Workflow
public struct FileCompressorWorkflow {
  public typealias Activities = FileCompressorActivities

  public struct Input: Codable, Sendable {
    public let urls: [URL]
    public let archiveName: String
    public let compressor: Compressor

    public init(urls: [URL], archiveName: String, compressor: Compressor) {
      self.urls = urls
      self.archiveName = archiveName
      self.compressor = compressor
    }
  }

  public struct Output: Codable, Sendable {
    public let archivePath: String

    public init(archivePath: String) {
      self.archivePath = archivePath
    }
  }

  public init() {}

  public func run(input: Input, context: WorkflowContext) async throws -> Output {
    try? await input.compressor.notify(.started)

    let files: [String] = try await withThrowingTaskGroup(of: (Int, String).self) { group in
      for (index, url) in input.urls.enumerated() {
        group.addTask {
          let path = try await context.executeActivity(
            FileCompressorActivities.Activities.FetchAndStore.self,
            input: .init(url: url, index: index, compressor: input.compressor)
          )
          try? await input.compressor.notify(.download(file: url, fileIndex: index, fraction: 1.0))
          return (index, path)
        }
      }
      var results: [(Int, String)] = []
      for try await result in group { results.append(result) }
      return results.sorted { $0.0 < $1.0 }.map(\.1)
    }

    let archivePath = try await context.executeActivity(
      FileCompressorActivities.Activities.CreateArchive.self,
      input: .init(files: files, archiveName: input.archiveName)
    )

    try await context.executeActivity(
      FileCompressorActivities.Activities.DeleteFiles.self,
      input: files
    )

    return Output(archivePath: archivePath)
  }
}
