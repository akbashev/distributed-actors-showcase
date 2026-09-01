import Foundation

public struct Hotel: Sendable, Codable {
  public let name: String
  public let costCents: Int

  public init(name: String, costCents: Int) {
    self.name = name
    self.costCents = costCents
  }
}

public struct City: Sendable, Codable {
  public let name: String
  public let flightCostCents: Int
  public let hotels: [Hotel]

  public init(name: String, flightCostCents: Int, hotels: [Hotel]) {
    self.name = name
    self.flightCostCents = flightCostCents
    self.hotels = hotels
  }

  public static let top10: [City] = [
    City(
      name: "Paris",
      flightCostCents: 450_00,
      hotels: [
        Hotel(name: "Ritz Paris", costCents: 1500_00),
        Hotel(name: "Hotel Le Meurice", costCents: 1200_00),
        Hotel(name: "Pullman Paris Tour Eiffel", costCents: 400_00),
        Hotel(name: "ibis Paris Centre", costCents: 150_00),
      ]
    ),
    City(
      name: "London",
      flightCostCents: 350_00,
      hotels: [
        Hotel(name: "The Savoy", costCents: 1400_00),
        Hotel(name: "Shangri-La The Shard", costCents: 1300_00),
        Hotel(name: "Hilton London Metropole", costCents: 350_00),
        Hotel(name: "The Hoxton Holborn", costCents: 280_00),
      ]
    ),
    City(
      name: "Rome",
      flightCostCents: 300_00,
      hotels: [
        Hotel(name: "Hotel Hassler", costCents: 1100_00),
        Hotel(name: "Hotel Artemide", costCents: 450_00),
        Hotel(name: "Best Western Roma", costCents: 180_00),
      ]
    ),
    City(
      name: "Berlin",
      flightCostCents: 250_00,
      hotels: [
        Hotel(name: "Hotel Adlon Kempinski", costCents: 950_00),
        Hotel(name: "Michelberger Hotel", costCents: 220_00),
        Hotel(name: "Motel One Berlin", costCents: 120_00),
      ]
    ),
    City(
      name: "Amsterdam",
      flightCostCents: 320_00,
      hotels: [
        Hotel(name: "Waldorf Astoria Amsterdam", costCents: 1200_00),
        Hotel(name: "Pulitzer Amsterdam", costCents: 600_00),
        Hotel(name: "CitizenM Amsterdam", costCents: 200_00),
      ]
    ),
    City(
      name: "Madrid",
      flightCostCents: 280_00,
      hotels: [
        Hotel(name: "Four Seasons Madrid", costCents: 1300_00),
        Hotel(name: "Only YOU Hotel", costCents: 350_00),
        Hotel(name: "Hostal Persal", costCents: 100_00),
      ]
    ),
    City(
      name: "Vienna",
      flightCostCents: 290_00,
      hotels: [
        Hotel(name: "Hotel Sacher", costCents: 1000_00),
        Hotel(name: "Hotel Bristol", costCents: 500_00),
        Hotel(name: "Motel One Wien", costCents: 130_00),
      ]
    ),
    City(
      name: "Prague",
      flightCostCents: 220_00,
      hotels: [
        Hotel(name: "Four Seasons Prague", costCents: 900_00),
        Hotel(name: "Hotel Kings Court", costCents: 300_00),
        Hotel(name: "Czech Inn", costCents: 80_00),
      ]
    ),
    City(
      name: "Barcelona",
      flightCostCents: 310_00,
      hotels: [
        Hotel(name: "W Barcelona", costCents: 800_00),
        Hotel(name: "Hotel Majestic", costCents: 550_00),
        Hotel(name: "Generator Barcelona", costCents: 90_00),
      ]
    ),
    City(
      name: "Lisbon",
      flightCostCents: 330_00,
      hotels: [
        Hotel(name: "Four Seasons Lisbon", costCents: 1100_00),
        Hotel(name: "Tivoli Avenida Liberdade", costCents: 400_00),
        Hotel(name: "Selina Secret Garden", costCents: 120_00),
      ]
    ),
  ]
}
