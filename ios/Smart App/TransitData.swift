import Foundation

// The bundled SMART data (data.json, built by the web prototype's scripts/build-data.mjs)
// and the live snapshot served by the Cloudflare Worker. Field names match the JSON.

nonisolated struct TransitData: Decodable {
    let timezone: String
    let stations: [Station]
    let shapes: [String: [ShapePoint]]
    let trips: [Trip]
    let calendar: [ServiceCalendar]
    let exceptions: [ServiceException]
    let realtime: Realtime
    let crossings: [Crossing]

    static func loadBundled() -> TransitData {
        guard let url = Bundle.main.url(forResource: "data", withExtension: "json"),
              let bytes = try? Data(contentsOf: url),
              let data = try? JSONDecoder().decode(TransitData.self, from: bytes)
        else { fatalError("data.json is missing from the app bundle or can't be read") }
        return data
    }
}

nonisolated struct Station: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let lat: Double
    let lon: Double
}

/// A point on a track shape: longitude, latitude, and meters along the track.
nonisolated struct ShapePoint: Decodable {
    let lon: Double
    let lat: Double
    let dist: Double

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        lon = try c.decode(Double.self)
        lat = try c.decode(Double.self)
        dist = try c.decode(Double.self)
    }
}

nonisolated struct Trip: Decodable, Identifiable {
    let id: String
    let name: String
    let headsign: String
    /// 1 = northbound, 0 = southbound.
    let dir: Int
    let service: String
    let shape: String
    let stops: [TripStop]
}

/// A stop on a trip's timeline. Times are seconds since the service day's midnight.
nonisolated struct TripStop: Decodable {
    var stopId: String
    var arr: Double
    var dep: Double
    /// Meters along the trip's shape.
    var dist: Double

    init(stopId: String, arr: Double, dep: Double, dist: Double) {
        self.stopId = stopId
        self.arr = arr
        self.dep = dep
        self.dist = dist
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        stopId = try c.decode(String.self)
        arr = try c.decode(Double.self)
        dep = try c.decode(Double.self)
        dist = try c.decode(Double.self)
    }
}

nonisolated struct ServiceCalendar: Decodable {
    let service: String
    /// Sunday first.
    let days: [Bool]
    let start: String
    let end: String
}

nonisolated struct ServiceException: Decodable {
    let service: String
    let date: String
    let add: Bool
}

nonisolated struct Crossing: Decodable {
    /// U.S. DOT Grade Crossing Identification Number, from the FRA Crossing Inventory.
    let id: String
    let lat: Double
    let lon: Double
    /// Street name and town, from the FRA Crossing Inventory.
    let street: String?
    let city: String?
    /// Street geometry leading away from the crossing, as [lon, lat] pairs.
    let arms: [[[Double]]]

    enum CodingKeys: String, CodingKey { case id, lat, lon, street, city, arms }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        street = try c.decodeIfPresent(String.self, forKey: .street)
        city = try c.decodeIfPresent(String.self, forKey: .city)
        arms = try c.decodeIfPresent([[[Double]]].self, forKey: .arms) ?? []
    }
}

// MARK: - Live data

nonisolated struct Realtime: Decodable {
    var tripUpdates: [TripUpdate] = []
    var tripUpdatesAt: Double?
    var vehicles: [Vehicle] = []
    var vehiclesAt: Double?

    enum CodingKeys: String, CodingKey { case tripUpdates, tripUpdatesAt, vehicles, vehiclesAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tripUpdates = try c.decodeIfPresent([TripUpdate].self, forKey: .tripUpdates) ?? []
        tripUpdatesAt = try c.decodeIfPresent(Double.self, forKey: .tripUpdatesAt)
        vehicles = try c.decodeIfPresent([Vehicle].self, forKey: .vehicles) ?? []
        vehiclesAt = try c.decodeIfPresent(Double.self, forKey: .vehiclesAt)
    }
}

nonisolated struct TripUpdate: Decodable {
    let trip: String
    let startDate: String
    let vehicle: String?
    let stops: [StopUpdate]
}

/// Predicted times (unix seconds) at one stop of a trip, by stop sequence (1-based).
nonisolated struct StopUpdate: Decodable {
    let seq: Int
    let arr: Double?
    let dep: Double?

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        seq = try c.decode(Int.self)
        arr = try c.decodeNil() ? nil : try c.decode(Double.self)
        dep = try c.decodeNil() ? nil : try c.decode(Double.self)
    }
}

nonisolated struct Vehicle: Decodable {
    let id: String
    let trip: String
    let lat: Double
    let lon: Double
    let status: String?
    let stopSeq: Int?
    let at: Double
}
