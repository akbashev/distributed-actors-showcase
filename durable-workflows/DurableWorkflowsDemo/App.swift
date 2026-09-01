import ArgumentParser
import Distributed
import DistributedCluster
import DurableWorkflows
import EventSourcing
import EventStores
import FileCompressor
import Foundation
import Hummingbird
import HummingbirdElementary
import HummingbirdWebSocket
import Logging
import PostgresEventStore
import PostgresNIO
import ServiceLifecycle
import TravelBooking
import VirtualActors

@main
struct DurableWorkflowsDemo: AsyncParsableCommand {
  @Option(name: .customLong("database-url"), help: "PostgreSQL connection URL. If omitted, uses file-based storage.")
  var databaseURL: String?

  func run() async throws {
    let store: any EventStore
    let postgresClient: PostgresClient?

    if let databaseURL {
      let environment = try Environment(databaseURL: databaseURL)
      var pgLogger = Logger(label: "postgres.pool")
      pgLogger.logLevel = .debug
      let client = PostgresClient(
        configuration: environment.database.dbConfig,
        backgroundLogger: pgLogger
      )
      store = PostgresEventStore(client: client)
      postgresClient = client
    } else {
      let dir = try FileCompressorActivities.applicationSupportDir()
        .appendingPathComponent("durable-workflows/journal")
      store = try FileEventStore(directory: dir)
      postgresClient = nil
    }

    try await Self.runApp(store: store, postgresClient: postgresClient)
  }

  // MARK: - Shared server logic

  static func runApp(store: any EventStore, postgresClient: PostgresClient?) async throws {
    let plugins: [any Plugin] = [
      ClusterSingletonPlugin(),
      ClusterVirtualActorsPlugin(),
      ClusterJournalPlugin { _ in store },
      DurableWorkflowsPlugin(),
    ]
    let daemon =
      await ClusterSystem
      .startClusterDaemon { settings in
        // FIXME: need to put plugins again, make ClusterDaemon Sendable in ClusterSystem
        let plugins: [any Plugin] = [
          ClusterSingletonPlugin(),
          ClusterVirtualActorsPlugin(),
          ClusterJournalPlugin { _ in store },
          DurableWorkflowsPlugin(),
        ]
        for plugin in plugins {
          settings.plugins.install(plugin: plugin)
        }
      }.system

    let system = await ClusterSystem("travel-booking-app") {
      $0.bindPort = 3660
      $0.discovery = .clusterd
      for plugin in plugins {
        $0.plugins.install(plugin: plugin)
      }
    }

    let streamConnections = StreamConnections(actorSystem: system, logger: system.log)
    let router = Router(context: BasicWebSocketRequestContext.self)

    router.addMiddleware {
      FileMiddleware(WebAppAssets.publicRoot, searchForIndexHtml: false)
    }

    // --- HTML ROUTES ---

    router.get("/") { _, _ in
      HTMLResponse { LandingPage() }
    }

    router.get("/travel") { _, _ in
      HTMLResponse {
        Page(pageContent: UserEntryFragment())
      }
    }

    // --- COMPRESSOR PROGRESS STORE ---

    let progressStore = WorkflowProgressStore()

    // --- COMPRESSOR ROUTES ---

    let log = Logger(label: "demo.compressor")

    router.get("/compressor") { _, _ in
      HTMLResponse { CompressorEntryPage() }
    }

    router.get("/compressor/session") { request, _ in
      guard let id = request.uri.queryParameters["id"].map(String.init), !id.isEmpty else {
        throw HTTPError(.badRequest)
      }
      let info = await Self.compressorStatus(id: id, system: system)
      let preview = info.flatMap(Self.inputPreview)
      return HTMLResponse {
        CompressorSessionPage(
          sessionId: id,
          hasWorkflow: info != nil,
          submittedURLs: preview?.urls ?? [],
          submittedArchiveName: preview?.archiveName ?? "archive"
        )
      }
    }

    router.get("/compressor/session/:id") { request, context in
      let id = try context.parameters.require("id")
      let info = await Self.compressorStatus(id: id, system: system)
      let preview = info.flatMap(Self.inputPreview)
      return HTMLResponse {
        CompressorSessionPage(
          sessionId: id,
          hasWorkflow: info != nil,
          submittedURLs: preview?.urls ?? [],
          submittedArchiveName: preview?.archiveName ?? "archive"
        )
      }
    }

    router.post("/compressor/compress/:id") { request, context in
      let id = try context.parameters.require("id")
      // The id lands in file paths via the workflow's storage dir —
      // reject anything that isn't a plain safe token.
      guard id == Self.sanitizedToken(id) else {
        throw HTTPError(.badRequest, message: "Invalid session id")
      }
      let body = try await request.body.collect(upTo: 1024 * 1024)
      let raw = String(buffer: body)

      var urlStrings: [String] = []
      var archiveName = "archive"
      for pair in raw.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map {
          String($0).removingPercentEncoding?.replacingOccurrences(of: "+", with: " ") ?? String($0)
        }
        guard parts.count == 2 else { continue }
        switch parts[0] {
        case "url": urlStrings.append(parts[1])
        case "archiveName": if !parts[1].isEmpty { archiveName = parts[1] }
        default: break
        }
      }

      // http(s) only — `URL(string:)` happily accepts file://, which would
      // turn the "download" activity into a local-file reader.
      let urls = urlStrings.filter { !$0.isEmpty }
        .compactMap { URL(string: $0) }
        .filter { $0.scheme == "http" || $0.scheme == "https" }
      guard !urls.isEmpty else { throw HTTPError(.badRequest, message: "No valid URLs") }
      guard urls.count <= 20 else { throw HTTPError(.badRequest, message: "Too many URLs (max 20)") }
      archiveName = Self.sanitizedToken(archiveName)
      log.info(
        "compress requested",
        metadata: ["session": "\(id)", "urls": "\(urls)", "archiveName": "\(archiveName)"]
      )

      await progressStore.store(urls: urls, archiveName: archiveName, for: id)

      return HTMLResponse { CompressorStatusContainer(workflowId: id) }
    }

    router.get("/compressor/status/:id") { request, context in
      let id = try context.parameters.require("id")
      let info = try await system.workflows.getStatus(type: FileCompressorWorkflow.self, options: WorkflowOptions(id: WorkflowID(rawValue: id)))
      var urls = await progressStore.urls(for: id)
      if urls.isEmpty {
        urls = Self.inputPreview(of: info)?.urls ?? []
      }
      return HTMLResponse {
        CompressorStatusCard(workflowId: id, info: info, urls: urls)
      }
    }

    router.get("/compressor/stream/:id") { request, context in
      let id = try context.parameters.require("id")

      let stream = AsyncStream<ByteBuffer> { sseContinuation in
        let task = Task {
          // The just-submitted form values live in the progress store; the
          // journal is the durable fallback after a server restart. Store
          // first: right after a re-submit its values are newer than the
          // journal's last executionStarted.
          let entry = await progressStore.entry(for: id)
          var resolvedURLs = entry?.urls ?? []
          var resolvedArchiveName = entry?.archiveName ?? "archive"

          if resolvedURLs.isEmpty, let info = await Self.compressorStatus(id: id, system: system),
            let preview = Self.inputPreview(of: info)
          {
            resolvedURLs = preview.urls
            resolvedArchiveName = preview.archiveName
          }

          let urls = resolvedURLs
          let archiveName = resolvedArchiveName
          log.info(
            "stream opened",
            metadata: ["session": "\(id)", "urls": "\(urls.count)", "source": "\(entry != nil ? "form" : "journal")"]
          )

          // Never auto-start a workflow the server knows nothing about: an
          // SSE connect alone (page open, browser-restored tab) must not
          // create work. Without URLs — from the form or the journal — there
          // is nothing to compress; show it and close the stream cleanly.
          guard !urls.isEmpty else {
            let html = """
              <div class="card" id="status-\(id)" sse-swap="update" hx-swap="outerHTML">\
              <p>No compression running for this session — start one with the form above.</p></div>
              """
            sseContinuation.yield(ByteBuffer(string: "event: update\ndata: \(html)\n\n"))
            sseContinuation.yield(ByteBuffer(string: "event: done\ndata:\n\n"))
            sseContinuation.finish()
            return
          }

          let compressor: Compressor = try await system.virtualActors.getActor(
            identifiedBy: .init(rawValue: "compressor-\(id)"),
            dependency: Compressor.Dependency()
          )

          let connection = Connection(actorSystem: system) { message, fractions in
            if let info = try? await system.workflows.getStatus(
              type: FileCompressorWorkflow.self,
              options: WorkflowOptions(id: WorkflowID(rawValue: id))
            ) {
              let html = CompressorStatusCard(workflowId: id, info: info, urls: urls, downloadFractions: fractions).render()
              sseContinuation.yield(ByteBuffer(string: "event: update\ndata: \(html)\n\n"))
              if case .completed = info.status {
                sseContinuation.yield(ByteBuffer(string: "event: done\ndata:\n\n"))
                sseContinuation.finish()
              }
            }
          }
          let connectionId = connection.id
          try await compressor.addConnection(connection)

          do {
            _ = try await compressor.fetch(id: WorkflowID(rawValue: id), urls: urls, name: archiveName)
            if let info = try? await system.workflows.getStatus(
              type: FileCompressorWorkflow.self,
              options: WorkflowOptions(id: WorkflowID(rawValue: id))
            ) {
              let html = CompressorStatusCard(workflowId: id, info: info, urls: urls).render()
              sseContinuation.yield(ByteBuffer(string: "event: update\ndata: \(html)\n\n"))
            }
            sseContinuation.yield(ByteBuffer(string: "event: done\ndata:\n\n"))
            sseContinuation.finish()
          } catch WorkflowRuntimeError.workflowInputMismatch {
            // Reconnect while running: the journal's input carries the
            // original Connection actor, so a fresh stream can't join as the
            // caller — poll and broadcast until done.
            log.info("workflow already running with its original input — reconnecting as observer", metadata: ["session": "\(id)"])
            while !Task.isCancelled {
              guard
                let info = try? await system.workflows.getStatus(
                  type: FileCompressorWorkflow.self,
                  options: WorkflowOptions(id: WorkflowID(rawValue: id))
                )
              else { break }
              let html = CompressorStatusCard(workflowId: id, info: info, urls: urls).render()
              sseContinuation.yield(ByteBuffer(string: "event: update\ndata: \(html)\n\n"))
              switch info.status {
              case .completed, .failed, .cancelled:
                sseContinuation.yield(ByteBuffer(string: "event: done\ndata:\n\n"))
                sseContinuation.finish()
                return
              default:
                try? await Task.sleep(for: .seconds(1))
              }
            }
          } catch is CancellationError {
            // Client disconnected — normal, Compressor keeps running
            log.debug("stream cancelled (client disconnected)", metadata: ["session": "\(id)"])
          } catch {
            log.error("compressor stream failed: \(error)", metadata: ["session": "\(id)"])
            if let info = try? await system.workflows.getStatus(
              type: FileCompressorWorkflow.self,
              options: WorkflowOptions(id: WorkflowID(rawValue: id))
            ) {
              let html = CompressorStatusCard(workflowId: id, info: info, urls: urls).render()
              sseContinuation.yield(ByteBuffer(string: "event: update\ndata: \(html)\n\n"))
            }
            sseContinuation.yield(ByteBuffer(string: "event: done\ndata:\n\n"))
            sseContinuation.finish()
          }
          try? await compressor.removeConnection(id: connectionId)
        }
        sseContinuation.onTermination = { _ in task.cancel() }
      }

      return Response(
        status: .ok,
        headers: [
          .contentType: "text/event-stream",
          .cacheControl: "no-cache",
        ],
        body: ResponseBody(asyncSequence: stream)
      )
    }

    router.get("/compressor/download/:id") { request, context in
      let id = try context.parameters.require("id")
      let info = try await system.workflows.getStatus(
        type: FileCompressorWorkflow.self,
        options: WorkflowOptions(id: WorkflowID(rawValue: id))
      )
      guard case .completed(let data) = info.status,
        let result = try? JSONDecoder().decode(FileCompressorWorkflow.Output.self, from: data)
      else {
        throw HTTPError(.notFound)
      }
      // Stream the archive in chunks — never buffer the whole ZIP in memory.
      let fileURL = URL(fileURLWithPath: result.archivePath)
      let stream = AsyncStream<ByteBuffer> { continuation in
        let task = Task {
          do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            while !Task.isCancelled {
              guard let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
              continuation.yield(ByteBuffer(data: chunk))
            }
            continuation.finish()
          } catch {
            continuation.finish()
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
      let archiveName = await progressStore.entry(for: id)?.archiveName ?? "archive"
      return Response(
        status: .ok,
        headers: [
          .contentType: "application/zip",
          .contentDisposition: "attachment; filename=\"\(archiveName).zip\"",
        ],
        body: .init(asyncSequence: stream)
      )
    }

    router.get("/dashboard") { request, context in
      guard let username = request.uri.queryParameters["username"].map(String.init) else {
        throw HTTPError(.badRequest)
      }
      let user = try await system.getUser(username: username)
      let balance = try await user.getBalance()
      let workflows = try await user.getWorkflows()

      var activeWorkflow: (id: String, info: WorkflowStatusInfo)? = nil
      if let latestId = workflows.first {
        let options = WorkflowOptions(id: WorkflowID(rawValue: latestId))
        if let info = try? await system.workflows.getStatus(type: TravelBookingWorkflow.self, options: options) {
          activeWorkflow = (latestId, info)
        }
      }

      return HTMLResponse {
        Page(
          pageContent: DashboardFragment(
            username: username,
            balance: balance,
            recentWorkflows: workflows,
            activeWorkflow: activeWorkflow
          ),
          username: username
        )
      }
    }

    router.get("/hotels") { request, _ in
      guard let indexStr = request.uri.queryParameters["cityIndex"],
        let index = Int(indexStr),
        index < City.top10.count
      else {
        throw HTTPError(.badRequest)
      }
      return HTMLResponse {
        HotelOptionsFragment(hotels: City.top10[index].hotels)
      }
    }

    router.get("/status/{id}") { request, context in
      let id = try context.parameters.require("id")
      let options = WorkflowOptions(id: WorkflowID(rawValue: id))
      let info = try await system.workflows.getStatus(type: TravelBookingWorkflow.self, options: options)

      let result: TravelBookingWorkflow.BookingResult? =
        switch info.status {
        case .completed(let outputData):
          {
            let decoder = JSONDecoder()
            decoder.userInfo[.actorSystemKey] = system
            return try? decoder.decode(TravelBookingWorkflow.BookingResult.self, from: outputData)
          }()
        default: .none
        }

      let error: String? =
        switch info.status {
        case .failed(let error): error
        default: .none
        }

      return HTMLResponse {
        WorkflowStatusCard(
          id: id,
          status: info.status.name,
          events: info.events,
          result: result,
          error: error
        )
      }
    }

    router.post("/crash") { _, _ in
      print("💥 CRASHING SERVER FOR DURABILITY TEST...")
      Foundation.exit(1)
      return HTTPResponse.Status.ok
    }

    // --- WEBSOCKET ROUTE ---

    router.ws("/ws") { request, _ in
      guard request.uri.queryParameters["username"] != nil else {
        return .dontUpgrade
      }
      return .upgrade([:])
    } onUpgrade: { inbound, outbound, context in
      let username = context.request.uri.queryParameters["username"].map(String.init) ?? "unknown"
      let outputStream = try await streamConnections.addWSConnectionFor(sessionId: username, inbound: inbound)
      for await updates in outputStream {
        for update in updates {
          if let html = try await renderMessageUpdate(update, username: username, system: system) {
            try await outbound.write(.text(html))
          }
        }
      }
    }

    var hb = Application(
      router: router,
      server: .http1WebSocketUpgrade(webSocketRouter: router),
      configuration: .init(address: .hostname("127.0.0.1", port: 8080))
    )

    let virtualNode = await VirtualNode(actorSystem: system)
    var travelworkers: [DurableActivityDispatchWorker<TravelBookingWorkflow>] = []
    var compressorWorkers: [DurableActivityDispatchWorker<FileCompressorWorkflow>] = []

    for _ in 0..<10 {
      await travelworkers.append(DurableActivityDispatchWorker<TravelBookingWorkflow>(actorSystem: system))
      await compressorWorkers.append(DurableActivityDispatchWorker<FileCompressorWorkflow>(actorSystem: system))
    }

    if let postgresClient {
      hb.addServices(postgresClient, daemon, system, streamConnections)
    } else {
      hb.addServices(daemon, system, streamConnections)
    }

    try await hb.run()
  }

  // MARK: - WebSocket message rendering

  private static func renderMessageUpdate(
    _ update: BookingMessage.SystemUpdate,
    username: String,
    system: ClusterSystem
  ) async throws -> String? {
    switch update {
    case .balanceUpdated(let balance):
      return BalanceFragment(balance: balance, oob: true).render()

    case .workflowUpdated(let workflowId, let info):
      let result: TravelBookingWorkflow.BookingResult? =
        switch info.status {
        case .completed(let outputData):
          {
            let decoder = JSONDecoder()
            decoder.userInfo[.actorSystemKey] = system
            return try? decoder.decode(TravelBookingWorkflow.BookingResult.self, from: outputData)
          }()
        default: .none
        }

      let error: String? =
        switch info.status {
        case .failed(let error): error
        default: .none
        }
      let isActive = info.status == .running
      return WorkflowStatusFragment(
        id: workflowId,
        status: info.status.name,
        events: info.events,
        result: result,
        error: error,
        oob: true
      ).render() + BookingButtonFragment(isDisabled: isActive, oob: true).render()

    case .workflowListUpdated(let ids):
      return RecentBookingsFragment(ids: ids, oob: true).render()

    case .error(let message):
      return "<div id='active-workflow-area' hx-swap-oob='true' class='card' style='color:red'>Error: \(message)</div>"
    }
  }

  // MARK: - Compressor session state

  /// Status of a session's workflow, recovered from the journal — nil means
  /// no workflow exists for this id (getStatus activates an actor for ANY
  /// id, so only a non-idle status counts as "exists").
  private static func compressorStatus(id: String, system: ClusterSystem) async -> WorkflowStatusInfo? {
    guard
      let info = try? await system.workflows.getStatus(
        type: FileCompressorWorkflow.self,
        options: WorkflowOptions(id: WorkflowID(rawValue: id))
      ),
      info.status != .idle
    else { return nil }
    return info
  }

  /// The submitted input of the LATEST run — a restarted session journals one
  /// `executionStarted` per run, so `first` would show a superseded submission.
  private static func inputPreview(of info: WorkflowStatusInfo) -> WorkflowInputPreview? {
    guard
      let startedEvent = info.events.last(where: {
        if case .executionStarted = $0 { return true }
        return false
      }),
      case .executionStarted(let inputData) = startedEvent
    else { return nil }
    return try? JSONDecoder().decode(WorkflowInputPreview.self, from: inputData)
  }

  // MARK: - Environment

  /// Strips a client-supplied token (session id, archive name) down to a
  /// path-safe value: alphanumerics plus `-_.`, capped at 50 chars, never a
  /// bare `.`/`..` (path traversal).
  private static func sanitizedToken(_ raw: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-_.")
    let trimmed = String(raw.unicodeScalars.filter(allowed.contains).prefix(50))
    return trimmed.isEmpty || trimmed.allSatisfy({ $0 == "." }) ? "archive" : trimmed
  }

  struct Environment: Sendable {
    let database: Database

    struct Database: Sendable {
      let host: String
      let port: Int
      let username: String
      let password: String?
      let name: String?
      let tls: Bool
    }

    init(database: Database) {
      self.database = database
    }

    init(databaseURL: String) throws {
      let tls = (ProcessInfo.processInfo.environment["DB_TLS"] ?? "false") == "true"
      guard !databaseURL.isEmpty, let components = URLComponents(string: databaseURL) else {
        throw DurableWorkflowsDemoError.invalidDatabaseUrl(databaseURL)
      }
      self.database = Database(
        host: components.host ?? "localhost",
        port: components.port ?? 5432,
        username: components.user ?? "postgres",
        password: components.password,
        name: components.path.trimmingCharacters(in: ["/"]),
        tls: tls
      )
    }
  }
}

// MARK: - Extensions

private actor WorkflowProgressStore {
  struct Entry {
    let urls: [URL]
    let archiveName: String
  }

  private var entries: [String: Entry] = [:]

  func store(urls: [URL], archiveName: String, for id: String) {
    entries[id] = Entry(urls: urls, archiveName: archiveName)
  }

  func entry(for id: String) -> Entry? {
    entries[id]
  }

  func urls(for id: String) -> [URL] {
    entries[id]?.urls ?? []
  }
}

extension ClusterSystem: @retroactive Service {
  public func run() async throws {
    try await self.terminated
  }
}

private struct WorkflowInputPreview: Decodable {
  let urls: [URL]
  let archiveName: String
}

enum DurableWorkflowsDemoError: Swift.Error {
  case invalidDatabaseUrl(String?)
}

extension DurableWorkflowsDemo.Environment.Database {
  var dbConfig: PostgresClient.Configuration {
    .init(
      host: self.host,
      port: self.port,
      username: self.username,
      password: self.password,
      database: self.name,
      tls: self.tls ? .require(.makeClientConfiguration()) : .disable
    )
  }
}
