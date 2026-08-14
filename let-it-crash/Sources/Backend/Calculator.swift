import Distributed
import DistributedCluster
import EventSourcing
import Foundation
import VirtualActors

@EventSourced
@VirtualActor
public distributed actor Calculator {
  public typealias ActorSystem = ClusterSystem
  public typealias Event = HistoryEvent

  public struct Dependency: Codable, Sendable {
    public let clientId: Int

    public init(clientId: Int) {
      self.clientId = clientId
    }
  }

  private let clientId: Int
  private let pool: WorkerPool<CalculationWorker>
  private let persistenceID: String

  public struct State: Codable, Sendable {
    public var connectedAt: Date?
    public var records: [CalculationRecord] = []

    public init() {}
  }

  public var state = State()

  public init(actorSystem: ClusterSystem, clientId: Int) async throws {
    self.actorSystem = actorSystem
    self.clientId = clientId
    self.persistenceID = "calculator-history-\(clientId)"
    let poolSettings = WorkerPoolSettings<CalculationWorker>(
      selector: .dynamic(.calculatorWorkers),
      strategy: .simpleRoundRobin
    )
    self.pool = try await WorkerPool(
      settings: poolSettings,
      actorSystem: actorSystem
    )
    try await actorSystem.journal.register(actor: self, with: self.persistenceID)
  }

  public static func spawn(on actorSystem: ClusterSystem, dependency: any Sendable & Codable)
    async throws -> Self
  {
    guard let dependency = dependency as? Dependency else {
      throw VirtualActorError.spawnDependencyTypeMismatch
    }
    return try await Self(actorSystem: actorSystem, clientId: dependency.clientId)
  }

  distributed public func connect() async throws {
    let event = HistoryEvent.connected(Date())
    try await self.emit(event: event)
  }

  distributed public func calculate(_ work: CalculationWork) async throws -> CalculationRecord {
    let calculation = try await self.pool.submit(work: work)
    let event = HistoryEvent.recorded(calculation)
    try await self.emit(event: event)
    return calculation
  }

  distributed public func history() -> [CalculationRecord] {
    self.state.records.reversed()
  }

  distributed public func handleEvent(_ event: HistoryEvent) {
    self.apply(event)
  }

  private func apply(_ event: HistoryEvent) {
    switch event {
    case .connected(let date):
      self.state.connectedAt = date
    case .recorded(let record):
      self.state.records.append(record)
    }
  }
}
