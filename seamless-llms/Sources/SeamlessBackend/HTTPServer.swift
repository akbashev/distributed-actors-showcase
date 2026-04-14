import AsyncAlgorithms
import DistributedCluster
import EventSourcing
import Foundation
import Hummingbird
import HummingbirdWebSocket
import OpenAPIHummingbird
import OpenAPIRuntime
import SeamlessAPI
import SeamlessCore
import ServiceLifecycle
import VirtualActors

extension SeamlessBackend {
  public struct HTTPConfiguration: Sendable {
    public let host: String
    public let port: Int

    public init(
      host: String = "127.0.0.1",
      port: Int = 8080
    ) {
      self.host = host
      self.port = port
    }
  }

  public struct HTTPServer: Service {
    public let configuration: HTTPConfiguration
    private var schemas: [any SeamlessCore.SeamlessSchema.Type]
    public let actorSystem: ClusterSystem

    public init(
      configuration: HTTPConfiguration,
      schemas: [any SeamlessCore.SeamlessSchema.Type],
      configuredWith configureSettings: sending (inout ClusterSystemSettings) -> Void
    ) async {
      self.configuration = configuration
      self.schemas = schemas
      self.actorSystem = await ClusterSystem("seamless-server", configuredWith: configureSettings)
    }

    public func run() async throws {
      let router = Router()
      let connections = await SessionService(
        actorSystem: self.actorSystem,
        schemas: self.schemas,
        logger: actorSystem.log
      )
      let api = HTTPAPI(connections: connections)
      try api.registerHandlers(on: router)
      let app = Application(
        router: router,
        configuration: .init(
          address: .hostname(self.configuration.host, port: self.configuration.port),
          serverName: "seamless-backend-http"
        ),
        services: [connections]
      )
      return try await app.run()
    }

    /// Simple WebSocket upgrade handler that delegates the message stream to the caller.
    public static func websocketRouter(
      path: RouterPath = "api/ws",
      conversationIDQueryKey: Substring = "conversationID",
      onUpgrade: @escaping @Sendable (WebSocketInboundStream, WebSocketOutboundWriter, String) async throws -> Void
    ) -> Router<BasicWebSocketRequestContext> {
      let router = Router(context: BasicWebSocketRequestContext.self)
      router.ws(path) { request, _ in
        guard let conversationID = request.uri.queryParameters[conversationIDQueryKey].map(String.init),
          !conversationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          return .dontUpgrade
        }
        return .upgrade([:])
      } onUpgrade: { inbound, outbound, context in
        let conversationID =
          context.request.uri.queryParameters[conversationIDQueryKey]
          .map(String.init)?
          .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try await onUpgrade(inbound, outbound, conversationID)
      }
      return router
    }
  }

  public struct HTTPAPI: APIProtocol {

    private let connections: SessionService
    private let heartbeatSequence = AsyncTimerSequence(
      interval: .seconds(3),
      clock: .continuous
    )

    public init(
      connections: SessionService
    ) {
      self.connections = connections
    }

    public func execute(_ input: Operations.execute.Input) async throws -> Operations.execute.Output {
      let request =
        switch input.body {
        case .json(let value):
          value
        }
      guard let pool = self.connections.pools[request.schemaID] else {
        throw SeamlessError.schemaUnavailable
      }
      return try await pool.sumbit(request.prompt)
    }

    public func sync(_ input: Operations.sync.Input) async throws -> Operations.sync.Output {
      let request = SessionService.Connection.RequestParameter(
        sessionId: input.path.sessionID,
        schemaID: input.headers.schemaID
      )
      let body =
        switch input.body {
        case .json(let value): value
        }
      try await self.connections.sync(messages: body.messages, transcript: body.transcript, for: request)
      return .ok
    }

    public func connectConversation(_ input: Operations.connectConversation.Input) async throws -> Operations.connectConversation.Output {
      let inputStream =
        switch input.body {
        case .application_jsonl(let body):
          body.asDecodedJSONLines(
            of: Components.Schemas.SeamlessStreamMessage.self
          )
        }
      let request = SessionService.Connection.RequestParameter(
        sessionId: input.path.sessionID,
        schemaID: input.headers.schemaID
      )
      let outputStream = try await self.connections.addJSONLConnectionFor(
        request: request,
        inbound: inputStream
      )

      let messageStream = AsyncThrowingStream<Components.Schemas.SeamlessStreamMessage, Swift.Error> { continuation in
        continuation.yield(
          .assistant(
            .init(
              role: .assistant,
              createdAt: Date(),
              message: .heartbeat(.init(_type: .heartbeat))
            )
          )
        )
        let listener = Task {
          for try await output in outputStream {
            switch output {
            case .response(let message):
              continuation.yield(message)
            case .close(_):
              continuation.finish()
            }
          }
          continuation.finish()
        }

        continuation.onTermination = { _ in
          listener.cancel()
          Task {
            try await self.connections.removeJSONLConnectionFor(request: request)
          }
        }
      }

      let heartbeatStream = self.heartbeatSequence
        .map { _ in
          Components.Schemas.SeamlessStreamMessage
            .assistant(
              .init(
                role: .assistant,
                createdAt: Date(),
                message: .heartbeat(.init(_type: .heartbeat))
              )
            )
        }

      let eventStream = merge(messageStream, heartbeatStream)
      let chosenContentType = input.headers.accept.sortedByQuality().first ?? .init(contentType: .application_jsonl)
      let responseBody: Operations.connectConversation.Output.Ok.Body =
        switch chosenContentType.contentType {
        case .application_jsonl:
          .application_jsonl(
            .init(
              eventStream.asEncodedJSONLines(),
              length: .unknown,
              iterationBehavior: .single
            )
          )
        case .other:
          throw SeamlessError.connectionCantBeEstablished
        }
      return .ok(.init(body: responseBody))
    }
  }
}
