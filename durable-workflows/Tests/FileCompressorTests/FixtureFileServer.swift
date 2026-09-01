import Foundation
import Hummingbird
import Synchronization

/// Tiny in-process HTTP fixture server: serves two small text files at known
/// paths plus a "flaky" file that fails with 500 a configurable number of
/// times before succeeding. Counts hits per path so tests can assert what was
/// (not) re-fetched. No external network.
final class FixtureFileServer: Sendable {

  let port: Int

  private let counts = Mutex<[String: Int]>([:])
  private let _flakyFailuresRemaining = Mutex(0)

  static let alphaContent = String(repeating: "alpha fixture contents. ", count: 50)
  static let betaContent = String(repeating: "beta fixture contents. ", count: 50)
  static let flakyContent = String(repeating: "flaky fixture contents. ", count: 50)

  init(port: Int) {
    self.port = port
  }

  var alphaURL: URL { URL(string: "http://127.0.0.1:\(self.port)/alpha.txt")! }
  var betaURL: URL { URL(string: "http://127.0.0.1:\(self.port)/beta.txt")! }
  var flakyURL: URL { URL(string: "http://127.0.0.1:\(self.port)/flaky.txt")! }

  var flakyFailuresRemaining: Int {
    get { self._flakyFailuresRemaining.withLock { $0 } }
    set { self._flakyFailuresRemaining.withLock { $0 = newValue } }
  }

  func hitCount(for path: String) -> Int {
    self.counts.withLock { $0[path] ?? 0 }
  }

  /// Boots the server in the background and waits until it answers.
  func start() async throws {
    let router = Router()
    router.get("/health") { _, _ in
      "ok"
    }
    router.get("/alpha.txt") { _, _ -> String in
      self.counts.withLock { $0["/alpha.txt", default: 0] += 1 }
      return Self.alphaContent
    }
    router.get("/beta.txt") { _, _ -> String in
      self.counts.withLock { $0["/beta.txt", default: 0] += 1 }
      return Self.betaContent
    }
    router.get("/flaky.txt") { _, _ async throws -> String in
      self.counts.withLock { $0["/flaky.txt", default: 0] += 1 }
      // Delay the failure so concurrently fetched good files finish (and
      // journal) first — keeps the retry assertions deterministic.
      try await Task.sleep(for: .milliseconds(500))
      let shouldFail = self._flakyFailuresRemaining.withLock { remaining -> Bool in
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
      }
      if shouldFail {
        throw HTTPError(.internalServerError)
      }
      return Self.flakyContent
    }

    let app = Application(
      router: router,
      configuration: .init(address: .hostname("127.0.0.1", port: self.port))
    )
    Task {
      try await app.runService()
    }

    let healthURL = URL(string: "http://127.0.0.1:\(self.port)/health")!
    try await eventually(interval: .milliseconds(100)) {
      (try? await URLSession.shared.data(from: healthURL)).map { _ in true } ?? false
    }
  }
}
