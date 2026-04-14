import Foundation
import SeamlessCore

#if canImport(FoundationModels)
import FoundationModels

@Generable
public struct TripPlan: SeamlessSchema {

  public static let identifier: String = "chat.reply.text.v1"
  public static let instructions: String? = "Create a 3-day itinerary from this request"

  @Guide(description: "An exciting name for the trip.")
  public let title: String

  @Guide(description: "City or place this trip is about.")
  public let destination: String

  @Guide(description: "A concise summary of the trip.")
  public let summary: String

  @Guide(.count(3))
  @Guide(description: "Three day-by-day plans.")
  public let days: [TripDay]

  public init(title: String, destination: String, summary: String, days: [TripDay]) {
    self.title = title
    self.destination = destination
    self.summary = summary
    self.days = days
  }
}

@Generable
public struct TripDay: Equatable, Codable, Sendable {
  @Guide(description: "A short title for this day.")
  public let title: String

  @Guide(.count(3))
  @Guide(description: "Exactly three activities.")
  public let activities: [TripActivity]

  public init(title: String, activities: [TripActivity]) {
    self.title = title
    self.activities = activities
  }
}

@Generable
public struct TripActivity: Equatable, Codable, Sendable {
  public let title: String
  public let details: String

  public init(title: String, details: String) {
    self.title = title
    self.details = details
  }
}

@Generable
public struct EmojiReaction: SeamlessSchema {
  public static let identifier: String = "chat.emoji.reaction.v1"
  public static let instructions: String? = "Return exactly three emoji reactions"

  @Guide(.count(3))
  @Guide(description: "Exactly three emoji reactions for location mentioned in the message.")
  public let emojis: [String]

  public init(emojis: [String]) {
    self.emojis = emojis
  }
}

extension TripPlan.PartiallyGenerated: Codable, Sendable {
  enum CodingKeys: String, CodingKey {
    case title, destination, summary, days
  }
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.title = try container.decodeIfPresent(String.PartiallyGenerated.self, forKey: .title)
    self.destination = try container.decodeIfPresent(String.PartiallyGenerated.self, forKey: .destination)
    self.summary = try container.decodeIfPresent(String.PartiallyGenerated.self, forKey: .summary)
    self.days = try container.decodeIfPresent([TripDay].PartiallyGenerated.self, forKey: .days)
    // GenerationID is not decodable and not needed for transport
    self.id = .init()
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(self.title, forKey: .title)
    try container.encodeIfPresent(self.destination, forKey: .destination)
    try container.encodeIfPresent(self.summary, forKey: .summary)
    try container.encodeIfPresent(self.days, forKey: .days)
  }
}
extension TripDay.PartiallyGenerated: Codable, Sendable {
  enum CodingKeys: String, CodingKey {
    case title, activities
  }
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.title = try container.decodeIfPresent(String.PartiallyGenerated.self, forKey: .title)
    self.activities = try container.decodeIfPresent([TripActivity].PartiallyGenerated.self, forKey: .activities)
    self.id = .init()
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(self.title, forKey: .title)
    try container.encodeIfPresent(self.activities, forKey: .activities)
  }
}
extension TripActivity.PartiallyGenerated: Codable, Sendable {
  enum CodingKeys: String, CodingKey {
    case title, details
  }
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.title = try container.decodeIfPresent(String.PartiallyGenerated.self, forKey: .title)
    self.details = try container.decodeIfPresent(String.PartiallyGenerated.self, forKey: .details)
    self.id = .init()
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(self.title, forKey: .title)
    try container.encodeIfPresent(self.details, forKey: .details)
  }
}
extension EmojiReaction.PartiallyGenerated: Codable, Sendable {
  enum CodingKeys: String, CodingKey {
    case emojis
  }
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.emojis = try container.decodeIfPresent([String].PartiallyGenerated.self, forKey: .emojis)
    self.id = .init()
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(self.emojis, forKey: .emojis)
  }
}

#else

public struct TripPlan: Equatable, Codable, Sendable {
  public let title: String
  public let destination: String
  public let summary: String
  public let days: [TripDay]

  public init(title: String, destination: String, summary: String, days: [TripDay]) {
    self.title = title
    self.destination = destination
    self.summary = summary
    self.days = days
  }
}

public struct TripDay: Equatable, Codable, Sendable {
  public let title: String
  public let activities: [TripActivity]

  public init(title: String, activities: [TripActivity]) {
    self.title = title
    self.activities = activities
  }
}

public struct TripActivity: Equatable, Codable, Sendable {
  public let title: String
  public let details: String

  public init(title: String, details: String) {
    self.title = title
    self.details = details
  }
}

public struct EmojiReaction: Equatable, Codable, Sendable {
  public let emojis: [String]

  public init(emojis: [String]) {
    self.emojis = emojis
  }
}
#endif
