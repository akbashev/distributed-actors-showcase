import ArgumentParser
import Distributed
import DistributedCluster
import DurableWorkflows
import EventSourcing
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
      let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
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
      HTMLResponse {
        Page(pageContent: UserEntryFragment())
      }
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
        let options = WorkflowOptions(id: latestId)
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
      let options = WorkflowOptions(id: id)
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
    let worker = await DurableActivityDispatchWorker<TravelBookingWorkflow>(actorSystem: system)

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

  // MARK: - Environment

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

extension ClusterSystem: @retroactive Service {
  public func run() async throws {
    try await self.terminated
  }
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
