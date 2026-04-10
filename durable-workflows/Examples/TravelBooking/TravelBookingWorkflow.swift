import DurableWorkflows
import Foundation

@Workflow
public struct TravelBookingWorkflow {
  public typealias Activities = TravelBookingActivities

  public struct TravelBookingRequest: Codable, Sendable {
    public let itineraryId: String
    public let travelerId: String
    public let flightCostCents: Int
    public let hotelCostCents: Int

    public init(itineraryId: String, travelerId: String, flightCostCents: Int, hotelCostCents: Int) {
      self.itineraryId = itineraryId
      self.travelerId = travelerId
      self.flightCostCents = flightCostCents
      self.hotelCostCents = hotelCostCents
    }
  }

  public struct BookingResult: Codable, Sendable, Equatable {
    public let status: String
    public let message: String
    public let flightCostCents: Int
    public let hotelCostCents: Int
    public let totalRefundedCents: Int

    public init(status: String, message: String, flightCostCents: Int = 0, hotelCostCents: Int = 0, totalRefundedCents: Int = 0) {
      self.status = status
      self.message = message
      self.flightCostCents = flightCostCents
      self.hotelCostCents = hotelCostCents
      self.totalRefundedCents = totalRefundedCents
    }
  }

  public init() {}

  public func run(
    input: TravelBookingRequest,
    context: WorkflowContext
  ) async throws -> BookingResult {
    let user: UserActor = try await context.getActor(
      identifiedBy: .init(rawValue: "user-\(input.travelerId)"),
      dependency: UserActor.Dependency(username: input.travelerId)
    )

    var flightId: String?
    var hotelId: String?
    var fundsHeld = false

    do {
      // 1. Hold Funds
      try await context.executeActivity(
        TravelBookingActivities.Activities.ReserveFunds.self,
        options: .init(startToCloseTimeoutMillis: 30_000),
        input: .init(user: user, amountCents: input.flightCostCents + input.hotelCostCents)
      )
      fundsHeld = true

      // 2. Reserve Flight
      flightId = try await context.executeActivity(
        TravelBookingActivities.Activities.ReserveFlight.self,
        options: .init(startToCloseTimeoutMillis: 30_000),
        input: .init(user: user, itineraryId: input.itineraryId, costCents: input.flightCostCents)
      )

      // 3. Reserve Hotel
      hotelId = try await context.executeActivity(
        TravelBookingActivities.Activities.ReserveHotel.self,
        options: .init(startToCloseTimeoutMillis: 30_000),
        input: .init(user: user, hotelId: input.itineraryId, costCents: input.hotelCostCents)
      )

      // 4. Finalize - Capture funds
      try await context.executeActivity(
        TravelBookingActivities.Activities.CaptureFunds.self,
        options: .init(startToCloseTimeoutMillis: 30_000),
        input: .init(user: user, amountCents: input.flightCostCents + input.hotelCostCents)
      )

      return BookingResult(
        status: "Confirmed",
        message: "Flight \(flightId!) and Hotel \(hotelId!) reserved.",
        flightCostCents: input.flightCostCents,
        hotelCostCents: input.hotelCostCents
      )
    } catch {
      // COMPENSATION
      // To bypass Task cancellation—run a separate task. This will be improved
      // by https://github.com/swiftlang/swift-evolution/blob/main/proposals/0504-task-cancellation-shields.md
      let task = Task {
        if let hId = hotelId {
          _ = try? await context.executeActivity(
            TravelBookingActivities.Activities.CancelHotel.self,
            options: .init(startToCloseTimeoutMillis: 30_000),
            input: .init(user: user, reservationId: hId)
          )
        }

        if let fId = flightId {
          _ = try? await context.executeActivity(
            TravelBookingActivities.Activities.CancelFlight.self,
            options: .init(startToCloseTimeoutMillis: 30_000),
            input: .init(user: user, reservationId: fId)
          )
        }

        if fundsHeld {
          _ = try? await context.executeActivity(
            TravelBookingActivities.Activities.ReleaseFunds.self,
            options: .init(startToCloseTimeoutMillis: 30_000),
            input: .init(user: user, amountCents: input.flightCostCents + input.hotelCostCents)
          )
        }

        if error is CancellationError {
          return BookingResult(
            status: "cancelled",
            message: "Saga was cancelled and compensated.",
            flightCostCents: input.flightCostCents,
            hotelCostCents: input.hotelCostCents,
            totalRefundedCents: input.flightCostCents + input.hotelCostCents
          )
        }
        throw error
      }
      return try await task.value
    }
  }
}
