import AsyncAlgorithms
import DistributedCluster
import DurableWorkflows
import Elementary
import Foundation
import Hummingbird
import HummingbirdWebSocket
import Logging
import ServiceLifecycle
import TravelBooking
import VirtualActors

public struct StreamConnections: Service {

  public typealias UpdateStream = AsyncStream<[BookingMessage.SystemUpdate]>

  actor OutboundConnections {
    private var connections: [String: Connection] = [:]
    private let logger: Logger

    func add(_ connection: Connection) async throws {
      self.connections[connection.id] = connection
    }

    func remove(_ connection: Connection) async throws {
      self.connections.removeValue(forKey: connection.id)
    }

    init(logger: Logger) {
      self.logger = logger
    }
  }

  public struct Connection: Identifiable, Sendable {
    public let id: String
    let inbound: WebSocketInboundStream
    let outbound: UpdateStream
    let bridge: TravelBooking.Connection
  }

  let logger: Logger
  let actorSystem: ClusterSystem
  private let outboundConnections: OutboundConnections
  private let connectionStream: AsyncStream<Connection>
  private let connectionContinuation: AsyncStream<Connection>.Continuation

  public init(actorSystem: ClusterSystem, logger: Logger) {
    self.actorSystem = actorSystem
    self.logger = logger
    self.outboundConnections = OutboundConnections(logger: logger)
    (self.connectionStream, self.connectionContinuation) = AsyncStream<Connection>.makeStream()
  }

  public func run() async throws {
    await withGracefulShutdownHandler {
      await withDiscardingTaskGroup { group in
        for await connection in self.connectionStream {
          group.addTask {
            self.logger.info("add connection", metadata: ["sessionId": .string(connection.id)])
            do {
              try await self.outboundConnections.add(connection)
              try await self.handleMessages(from: connection)
            } catch {
              self.logger.error("connection error", metadata: ["sessionId": .string(connection.id), "error": .string(String(describing: error))])
            }
            self.logger.info("remove connection", metadata: ["sessionId": .string(connection.id)])
            try? await self.outboundConnections.remove(connection)
          }
        }
        group.cancelAll()
      }
    } onGracefulShutdown: {
      self.connectionContinuation.finish()
    }
  }

  private func handleMessages(from connection: Connection) async throws {
    try await connection.bridge.send(message: .join)

    for try await input in connection.inbound.messages(maxSize: 1_000_000) {
      guard case .text(let text) = input else { continue }
      guard let data = text.data(using: .utf8) else { continue }

      // Flexible decoding
      let action: BookingMessage.UserAction? = {
        let decoder = JSONDecoder()
        if let action = try? decoder.decode(BookingMessage.UserAction.self, from: data) {
          return action
        }

        struct FlatAction: Codable {
          let `case`: String?
          let cityIndex: String?
          let hotelIndex: String?
          let workflowId: String?
        }

        if let flat = try? decoder.decode(FlatAction.self, from: data), let type = flat.case {
          switch type {
          case "addMoney": return .addMoney
          case "book":
            if let cStr = flat.cityIndex, let hStr = flat.hotelIndex,
              let city = Int(cStr), let hotel = Int(hStr)
            {
              return .book(cityIndex: city, hotelIndex: hotel)
            }
          case "abort":
            if let id = flat.workflowId {
              return .abort(workflowId: id)
            }
          default: break
          }
        }
        return nil
      }()

      if let action {
        try await connection.bridge.send(message: action)
      }
    }

    try? await connection.bridge.send(message: .disconnect)
  }

  public func addWSConnectionFor(
    sessionId: String,
    inbound: WebSocketInboundStream
  ) async throws -> UpdateStream {
    let (outbound, continuation) = AsyncStream<[BookingMessage.SystemUpdate]>.makeStream()
    let bridge = try await TravelBooking.Connection(actorSystem: self.actorSystem, sessionId: sessionId) { update in
      continuation.yield(update)
    }
    let connection = Connection(id: sessionId, inbound: inbound, outbound: outbound, bridge: bridge)
    self.connectionContinuation.yield(connection)
    return outbound
  }
}
