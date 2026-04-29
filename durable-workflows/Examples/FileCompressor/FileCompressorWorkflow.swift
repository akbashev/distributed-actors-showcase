import DurableWorkflows
import Foundation

@Workflow
public struct FileCompressorWorkflow {
  public typealias Activities = FileCompressorActivities

  public struct Input: Codable, Sendable {
    public let urls: [URL]
    public let archiveName: String
    public let session: Session

    public init(urls: [URL], archiveName: String, session: Session) {
      self.urls = urls
      self.archiveName = archiveName
      self.session = session
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
    try? await input.session.notify(.started)
    var files: [String] = []

    for (index, url) in input.urls.enumerated() {
      let path = try await context.executeActivity(
        FileCompressorActivities.Activities.FetchAndStore.self,
        input: .init(url: url, index: index, session: input.session)
      )
      files.append(path)
      try? await input.session.notify(.download(file: url, fileIndex: index, fraction: 1.0))
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
