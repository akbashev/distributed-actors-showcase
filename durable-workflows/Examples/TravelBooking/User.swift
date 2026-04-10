import Distributed
import DistributedCluster
import DurableWorkflows
import EventSourcing
import Foundation
import VirtualActors

public enum UserEvent: Codable, Sendable {
  case balanceAdded(amount: Int)
  case balanceDeducted(amount: Int)
  case workflowTracked(id: String)
  case fundsHeld(workflowID: String, amount: Int)
  case holdReleased(workflowID: String)
  case holdCaptured(workflowID: String)
}

@EventSourced
public distributed actor UserActor: VirtualActor {
  public typealias ActorSystem = ClusterSystem
  public typealias Event = UserEvent

  public struct Dependency: Codable, Sendable {
    public let username: String

    public init(username: String) {
      self.username = username
    }
  }

  struct State: Sendable {
    var balance: Int = 200_000
    var workflowIDs: [String] = []
    var holds: [String: Int] = [:]
    var holdsHistory: [String: Int] = [:]
  }

  private var state = State()
  private var connections: Set<Connection> = []
  private var currentTask: Task<Void, Never>?
  private let persistenceID: String

  public init(actorSystem: ClusterSystem, dependency: Dependency) async throws {
    self.actorSystem = actorSystem
    self.persistenceID = "user-\(dependency.username)"
    try await actorSystem.journal.register(actor: self, with: self.persistenceID)
  }

  public static func spawn(
    on actorSystem: ClusterSystem,
    dependency: any Sendable & Codable
  ) async throws -> Self {
    guard let typedDependency = dependency as? Dependency else {
      throw VirtualActorError.spawnDependencyTypeMismatch
    }
    return try await Self(actorSystem: actorSystem, dependency: typedDependency)
  }

  distributed public func send(message: BookingMessage.UserAction, from connection: Connection) async throws {
    switch message {
    case .join:
      self.connections.insert(connection)
      try await connection.broadcast([
        .balanceUpdated(balanceCents: self.getBalance()),
        .workflowListUpdated(ids: self.state.workflowIDs.reversed()),
      ])
      for id in self.state.workflowIDs {
        try? await self.pushStatus(id: id)
      }

    case .disconnect:
      self.connections.remove(connection)

    case .addMoney:
      try await self.addBalance(amount: 500_00)

    case .abort(let workflowId):
      self.currentTask?.cancel()
      self.currentTask = nil
      let options = WorkflowOptions(id: workflowId)
      try await self.actorSystem.workflows.cancel(type: TravelBookingWorkflow.self, options: options)
      try? await self.pushStatus(id: workflowId)

    case .book(let cityIndex, let hotelIndex):
      guard self.currentTask == nil else {
        try? await connection.broadcast([.error(message: "A booking is already in progress.")])
        return
      }
      let city = City.top10[cityIndex]
      let hotel = city.hotels[hotelIndex]
      let workflowId = "booking-\(city.name.lowercased())-\(UUID().uuidString.prefix(6))"

      try await self.trackWorkflow(id: workflowId)
      try? await self.pushStatus(id: workflowId)

      let input = TravelBookingWorkflow.TravelBookingRequest(
        itineraryId: "\(city.name) (\(hotel.name))",
        travelerId: self.username,
        flightCostCents: city.flightCostCents,
        hotelCostCents: hotel.costCents
      )

      self.currentTask = Task {
        defer { self.currentTask = nil }
        do {
          _ = try await self.actorSystem.workflows.execute(
            type: TravelBookingWorkflow.self,
            options: WorkflowOptions(id: workflowId),
            input: input
          )
        } catch {
          self.actorSystem.log.error("Workflow failed", metadata: ["error": "\(error)"])
        }
        try? await self.pushStatus(id: workflowId)
      }
    case .login:
      break
    }
  }

  distributed public func broadcast(_ updates: [BookingMessage.SystemUpdate]) async throws {
    for connection in self.connections {
      do {
        try await connection.broadcast(updates)
      } catch {
        self.connections.remove(connection)
      }
    }
  }

  private var username: String {
    self.persistenceID.replacingOccurrences(of: "user-", with: "")
  }

  distributed public func getBalance() -> Int {
    let totalHeld = self.state.holds.values.reduce(0, +)
    return self.state.balance - totalHeld
  }

  distributed public func addBalance(amount: Int) async throws {
    try await self.emit(event: .balanceAdded(amount: amount))
    try await self.broadcast([.balanceUpdated(balanceCents: self.getBalance())])
  }

  distributed public func holdFunds(workflowID: String, amount: Int) async throws {
    let available = self.getBalance()
    if available < amount {
      throw ApplicationError.typed(
        message: "Insufficient funds (Available: \(available), Required: \(amount))",
        type: "InsufficientFunds",
        isNonRetryable: true
      )
    }
    try await self.emit(event: .fundsHeld(workflowID: workflowID, amount: amount))
    try? await self.broadcast([.balanceUpdated(balanceCents: self.getBalance())])
  }

  distributed public func releaseHold(workflowID: String) async throws {
    if self.state.holds[workflowID] != nil || self.state.holdsHistory[workflowID] != nil {
      try await self.emit(event: .holdReleased(workflowID: workflowID))
      try? await self.broadcast([.balanceUpdated(balanceCents: self.getBalance())])
    }
  }

  distributed public func captureHold(workflowID: String) async throws {
    if let _ = self.state.holds[workflowID] {
      try await self.emit(event: .holdCaptured(workflowID: workflowID))
      try? await self.broadcast([.balanceUpdated(balanceCents: self.getBalance())])
    }
  }

  distributed public func trackWorkflow(id: String) async throws {
    if !self.state.workflowIDs.contains(id) {
      try await self.emit(event: .workflowTracked(id: id))
      try? await self.broadcast([.workflowListUpdated(ids: self.state.workflowIDs.reversed())])
    }
  }

  distributed public func notifyWorkflowUpdate(id: String) async throws {
    try await self.pushStatus(id: id)
  }

  distributed public func getWorkflows() -> [String] {
    self.state.workflowIDs.reversed()
  }

  private func fetchStatus(id: String) async throws -> WorkflowStatusInfo {
    try await self.actorSystem.workflows.getStatus(
      type: TravelBookingWorkflow.self,
      options: .init(id: id)
    )
  }

  private func pushStatus(id: String) async throws {
    if let info = try? await self.fetchStatus(id: id) {
      try await self.broadcast([.workflowUpdated(id: id, info: info)])
    }
  }

  distributed public func handleEvent(_ event: UserEvent) {
    switch event {
    case .balanceAdded(let amount):
      self.state.balance += amount
    case .balanceDeducted(let amount):
      self.state.balance -= amount
    case .workflowTracked(let id):
      self.state.workflowIDs.append(id)
    case .fundsHeld(let workflowID, let amount):
      self.state.holds[workflowID, default: 0] += amount
      self.state.holdsHistory[workflowID] = amount
    case .holdReleased(let workflowID):
      if self.state.holds[workflowID] == nil {
        if let amount = self.state.holdsHistory[workflowID] {
          self.state.balance += amount
        }
      }
      self.state.holds.removeValue(forKey: workflowID)
      self.state.holdsHistory.removeValue(forKey: workflowID)

    case .holdCaptured(let workflowID):
      if let amount = self.state.holds.removeValue(forKey: workflowID) {
        self.state.balance -= amount
      }
    }
  }
}

extension ClusterSystem {
  public func getUser(username: String) async throws -> UserActor {
    try await self.virtualActors.getActor(
      identifiedBy: .init(rawValue: "user-\(username)"),
      dependency: UserActor.Dependency(username: username)
    )
  }
}
