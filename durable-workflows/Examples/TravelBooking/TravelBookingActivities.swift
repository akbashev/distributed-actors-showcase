import Distributed
import DistributedCluster
import DurableWorkflows
import Foundation

@ActivityContainer
public struct TravelBookingActivities {
  public struct BalanceRequest: Codable, Sendable {
    public let user: UserActor
    public let amountCents: Int

    public init(user: UserActor, amountCents: Int) {
      self.user = user
      self.amountCents = amountCents
    }
  }

  public struct ReserveFlightRequest: Codable, Sendable {
    public let user: UserActor
    public let itineraryId: String
    public let costCents: Int

    public init(user: UserActor, itineraryId: String, costCents: Int) {
      self.user = user
      self.itineraryId = itineraryId
      self.costCents = costCents
    }
  }

  public struct ReserveHotelRequest: Codable, Sendable {
    public let user: UserActor
    public let hotelId: String
    public let costCents: Int

    public init(user: UserActor, hotelId: String, costCents: Int) {
      self.user = user
      self.hotelId = hotelId
      self.costCents = costCents
    }
  }

  public struct CompensationRequest: Codable, Sendable {
    public let user: UserActor
    public let reservationId: String

    public init(user: UserActor, reservationId: String) {
      self.user = user
      self.reservationId = reservationId
    }
  }

  @Activity
  public func reserveFunds(input: BalanceRequest, context: ActivityContext) async throws {
    try await Task.sleep(for: .seconds(3))
    try await input.user.holdFunds(workflowID: context.workflowID, amount: input.amountCents)
    try? await input.user.notifyWorkflowUpdate(id: context.workflowID)
  }

  @Activity
  public func captureFunds(input: BalanceRequest, context: ActivityContext) async throws {
    try await Task.sleep(for: .seconds(3))
    try await input.user.captureHold(workflowID: context.workflowID)
    try? await input.user.notifyWorkflowUpdate(id: context.workflowID)
  }

  @Activity
  public func releaseFunds(input: BalanceRequest, context: ActivityContext) async throws {
    try await Task.sleep(for: .seconds(3))
    try await input.user.releaseHold(workflowID: context.workflowID)
    try? await input.user.notifyWorkflowUpdate(id: context.workflowID)
  }

  @Activity
  public func reserveFlight(input: ReserveFlightRequest, context: ActivityContext) async throws -> String {
    // Simulating flight reservation API
    try await Task.sleep(for: .seconds(3))

    if input.itineraryId.contains("Fail") {
      try? await input.user.notifyWorkflowUpdate(id: context.workflowID)
      throw ApplicationError.typed(message: "Flight fully booked", type: "FlightUnavailable", isNonRetryable: false)
    }

    let id = "FLIGHT-\(UUID().uuidString.prefix(6))"
    try? await input.user.notifyWorkflowUpdate(id: context.workflowID)
    return id
  }

  @Activity
  public func reserveHotel(input: ReserveHotelRequest, context: ActivityContext) async throws -> String {
    // Simulating hotel reservation API
    try await Task.sleep(for: .seconds(3))

    if input.hotelId.contains("Overbooked") {
      try? await input.user.notifyWorkflowUpdate(id: context.workflowID)
      throw ApplicationError.typed(message: "Hotel overbooked", type: "HotelUnavailable", isNonRetryable: false)
    }

    let id = "HOTEL-\(UUID().uuidString.prefix(6))"
    try? await input.user.notifyWorkflowUpdate(id: context.workflowID)
    return id
  }

  @Activity
  public func cancelFlight(input: CompensationRequest, context: ActivityContext) async throws {
    try await Task.sleep(for: .seconds(3))
    try? await input.user.notifyWorkflowUpdate(id: context.workflowID)
  }

  @Activity
  public func cancelHotel(input: CompensationRequest, context: ActivityContext) async throws {
    try await Task.sleep(for: .seconds(3))
    try? await input.user.notifyWorkflowUpdate(id: context.workflowID)
  }
}
