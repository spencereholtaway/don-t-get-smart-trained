import Foundation
import CoreLocation

// The train model, ported from the web prototype (docs/plan.md, "Moving trains smoothly").
// The timetable moves the trains; live data only nudges them. A train's position is its
// distance along the track, worked out from the clock, then converted to a map point.

/// A clock time broken down in the SMART time zone.
struct ServiceDay {
    /// yyyyMMdd
    let ymd: String
    /// 0 = Sunday.
    let dow: Int
    /// Seconds since this day's midnight.
    let secs: Double
    /// Unix time of this day's midnight.
    let midnight: Double
}

struct TrainPosition: Identifiable {
    let trip: Trip
    let coordinate: CLLocationCoordinate2D
    /// Degrees clockwise from north, in the direction of travel.
    let bearing: Double
    let dist: Double
    let live: Bool
    /// Set while the train waits at its first station to start this trip (unix seconds it leaves).
    var departsAt: Double? = nil
    var id: String { trip.id }
}

/// One train calling at a station, or passing a point on the track.
struct Arrival {
    let trip: Trip
    /// Unix seconds: predicted when live, scheduled otherwise.
    let arr: Double
    let dep: Double
    let sched: Double
    let live: Bool
    /// Service days from today (0 = today).
    let dayOffset: Int
}

/// Live state of a level crossing, refreshed every second.
struct CrossingState: Identifiable {
    enum Heat: Equatable { case red(Double), yellow }

    let crossing: Crossing
    /// Meters along each shape.
    let distOnShape: [String: Double]
    /// The street arms cut into short pieces, each with its distance from the crossing.
    let pieces: [(coords: [CLLocationCoordinate2D], mid: Double)]
    var heat: Heat?
    /// Seconds until the next train reaches the crossing.
    var next = Double.infinity
    var nextLive = false
    var residual = 0.0
    var redNow = false
    var blockedNow = false
    /// The train behind the heat, and seconds until it reaches the crossing (negative once it's past).
    var cause: (trip: String, at: Double)?
    var id: String { crossing.id }
    var coordinate: CLLocationCoordinate2D { .init(latitude: crossing.lat, longitude: crossing.lon) }
}

/// The point on the track nearest you (Horse mode).
struct TrackPoint {
    let coordinate: CLLocationCoordinate2D
    /// Meters along each shape.
    let distOnShape: [String: Double]
}

final class TrainEngine {
    // Live predictions are used fully up to FRESH_S old, fading to the plain timetable by STALE_S.
    static let freshS = 8.0 * 60
    static let staleS = 10.0 * 60
    /// New live data eases in over this many seconds.
    static let blendS = 25.0

    let data: TransitData
    let tripsById: [String: Trip]
    let stationsById: [String: Station]
    let timeZone: TimeZone
    private let calendar: Calendar
    private var shapes: [String: Shape] = [:]
    /// Route line drawn on the map (the northbound shape).
    let routeCoordinates: [CLLocationCoordinate2D]
    /// The longest northbound trip; its shape is the reference line for the Horse track point.
    private let lineTrip: Trip

    private var predicted: [String: [TripStop]] = [:]
    private var prevPredicted: [String: [TripStop]]?
    private var blendStart = 0.0
    private(set) var snapshotAt: Double?
    /// Weight of live predictions in the last train frame, 0...1.
    private(set) var liveWeight = 0.0
    private var activeCache: [String: Set<String>] = [:]

    init(data: TransitData) {
        precondition(!data.stations.isEmpty && !data.trips.isEmpty, "data.json has no stations or trips")
        self.data = data
        tripsById = Dictionary(uniqueKeysWithValues: data.trips.map { ($0.id, $0) })
        stationsById = Dictionary(uniqueKeysWithValues: data.stations.map { ($0.id, $0) })
        timeZone = TimeZone(identifier: data.timezone) ?? TimeZone(identifier: "America/Los_Angeles")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        calendar = cal
        for (id, pts) in data.shapes { shapes[id] = Shape(points: pts) }
        let north = data.trips.first { $0.dir == 1 }?.shape ?? data.trips[0].shape
        routeCoordinates = data.shapes[north, default: []].map { .init(latitude: $0.lat, longitude: $0.lon) }
        lineTrip = data.trips.filter { $0.dir == 1 }.max { $0.stops.count < $1.stops.count } ?? data.trips[0]
        apply(data.realtime, now: Date.now.timeIntervalSince1970)
    }

    // MARK: Time

    /// Service-day times count from "noon minus 12 hours" (the GTFS rule, and what the web app does),
    /// so on daylight-saving change days they still match the timetable.
    func day(_ unix: Double) -> ServiceDay {
        let date = Date(timeIntervalSince1970: unix)
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: date) ?? calendar.startOfDay(for: date).addingTimeInterval(43_200)
        let midnight = noon.timeIntervalSince1970 - 43_200
        let ymd = String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        return ServiceDay(ymd: ymd, dow: (c.weekday ?? 1) - 1, secs: unix - midnight, midnight: midnight)
    }

    /// Midnight (unix) of a GTFS service date, yyyyMMdd.
    private func midnight(ofServiceDate ymd: String) -> Double {
        guard ymd.count == 8, let y = Int(ymd.prefix(4)), let m = Int(ymd.dropFirst(4).prefix(2)), let d = Int(ymd.suffix(2)),
              let noon = calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12))
        else { return day(Date.now.timeIntervalSince1970).midnight }
        return noon.timeIntervalSince1970 - 43_200
    }

    func activeServices(_ d: ServiceDay) -> Set<String> {
        if let cached = activeCache[d.ymd] { return cached }
        var set = Set(data.calendar.filter { $0.start <= d.ymd && d.ymd <= $0.end && $0.days.indices.contains(d.dow) && $0.days[d.dow] }.map(\.service))
        for e in data.exceptions where e.date == d.ymd {
            if e.add { set.insert(e.service) } else { set.remove(e.service) }
        }
        activeCache[d.ymd] = set
        return set
    }

    // MARK: Track geometry

    struct Shape {
        let lon: [Double], lat: [Double], dist: [Double]
        init(points: [ShapePoint]) {
            lon = points.map(\.lon); lat = points.map(\.lat); dist = points.map(\.dist)
        }
    }

    func point(onShape id: String, at d: Double) -> (coordinate: CLLocationCoordinate2D, bearing: Double) {
        guard let s = shapes[id], s.dist.count > 1 else { return (.init(), 0) }
        let hi = s.dist.count - 1
        if d <= s.dist[0] { return (.init(latitude: s.lat[0], longitude: s.lon[0]), Self.bearing(s, 0, 1)) }
        if d >= s.dist[hi] { return (.init(latitude: s.lat[hi], longitude: s.lon[hi]), Self.bearing(s, hi - 1, hi)) }
        var lo = 0, up = hi
        while up - lo > 1 {
            let m = (lo + up) / 2
            if s.dist[m] <= d { lo = m } else { up = m }
        }
        let span = s.dist[up] - s.dist[lo]
        let f = (d - s.dist[lo]) / (span == 0 ? 1 : span)
        return (.init(latitude: s.lat[lo] + (s.lat[up] - s.lat[lo]) * f, longitude: s.lon[lo] + (s.lon[up] - s.lon[lo]) * f),
                Self.bearing(s, lo, up))
    }

    private static func bearing(_ s: Shape, _ i: Int, _ j: Int) -> Double {
        bearing(from: (s.lon[i], s.lat[i]), to: (s.lon[j], s.lat[j]))
    }

    static func bearing(from a: (Double, Double), to b: (Double, Double)) -> Double {
        let r = Double.pi / 180
        let y = sin((b.0 - a.0) * r) * cos(b.1 * r)
        let x = cos(a.1 * r) * sin(b.1 * r) - sin(a.1 * r) * cos(b.1 * r) * cos((b.0 - a.0) * r)
        return (atan2(y, x) / r + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Projects a point onto a shape: its distance along the track and how far it is from it.
    func project(onShape id: String, lon: Double, lat: Double) -> (dist: Double, meters: Double) {
        guard let s = shapes[id], s.lon.count > 1 else { return (0, .infinity) }
        let k = cos(lat * .pi / 180)
        var bestE = Double.infinity, bestD = 0.0
        let px = lon * k, py = lat
        for i in 0..<(s.lon.count - 1) {
            let ax = s.lon[i] * k, ay = s.lat[i], bx = s.lon[i + 1] * k, by = s.lat[i + 1]
            let l = (bx - ax) * (bx - ax) + (by - ay) * (by - ay)
            let u = l > 0 ? max(0, min(1, ((px - ax) * (bx - ax) + (py - ay) * (by - ay)) / l)) : 0
            let e = hypot(ax + (bx - ax) * u - px, ay + (by - ay) * u - py)
            if e < bestE { bestE = e; bestD = s.dist[i] + (s.dist[i + 1] - s.dist[i]) * u }
        }
        return (bestD, bestE * 111_320)
    }

    // MARK: Motion

    /// Share of each run spent accelerating, and the same braking.
    private static let ramp = 0.2

    static func profile(_ p: Double) -> Double {
        let v = 1 / (1 - ramp)
        if p < ramp { return 0.5 * v * p * p / ramp }
        if p < 1 - ramp { return 0.5 * v * ramp + v * (p - ramp) }
        return 1 - 0.5 * v * (1 - p) * (1 - p) / ramp
    }

    static func profileInverse(_ f: Double) -> Double {
        var lo = 0.0, hi = 1.0
        for _ in 0..<30 {
            let m = (lo + hi) / 2
            if profile(m) < f { lo = m } else { hi = m }
        }
        return (lo + hi) / 2
    }

    /// Where the train on this timeline is at `t` (seconds since midnight), or nil if it isn't on the line.
    private func distAt(_ stops: [TripStop], _ t: Double) -> Double? {
        guard let first = stops.first, let last = stops.last else { return nil }
        if t < first.dep - 90 || t > last.arr + 45 { return nil }
        if t <= first.dep { return first.dist }
        for i in 0..<(stops.count - 1) {
            let a = stops[i], b = stops[i + 1]
            if t < a.dep { return a.dist } // dwelling at a
            if t < b.arr { return a.dist + (b.dist - a.dist) * Self.profile((t - a.dep) / (b.arr - a.dep)) }
        }
        return last.dist
    }

    /// When the train on this timeline reaches distance `dc`. Seconds since midnight.
    func timeAtDist(_ stops: [TripStop], _ dc: Double) -> Double? {
        for i in 0..<max(0, stops.count - 1) {
            let a = stops[i], b = stops[i + 1]
            if dc < a.dist || dc > b.dist { continue }
            if dc == a.dist { return a.arr }
            let span = b.dist - a.dist
            return a.dep + Self.profileInverse((dc - a.dist) / (span == 0 ? 1 : span)) * (b.arr - a.dep)
        }
        return nil
    }

    // MARK: Live data

    /// Takes a new live snapshot. Returns false if it's the one we already have.
    @discardableResult
    func apply(_ rt: Realtime, now: Double) -> Bool {
        // a new GPS fix counts, not just new trip updates
        let at = max(rt.tripUpdatesAt ?? 0, rt.vehiclesAt ?? 0)
        guard at > 0, at != snapshotAt else { return false }
        // ease from the previous snapshot only if it was today's and still fresh (not the bundled one)
        if let s = snapshotAt, at - s < Self.staleS, day(s).ymd == day(at).ymd { prevPredicted = predicted } else { prevPredicted = nil }
        blendStart = now
        predicted = buildPredicted(rt)
        snapshotAt = at
        return true
    }

    /// Each trip update lists predicted times for the stops still ahead. Turn those into a full
    /// adjusted timeline: predicted where we have it, scheduled plus the nearest known delay elsewhere.
    private func buildPredicted(_ rt: Realtime) -> [String: [TripStop]] {
        var out: [String: [TripStop]] = [:]
        for u in rt.tripUpdates {
            guard let trip = tripsById[u.trip] else { continue }
            let base = midnight(ofServiceDate: u.startDate)
            var bySeq: [Int: (arr: Double?, dep: Double?)] = [:]
            for s in u.stops where s.arr != nil || s.dep != nil {
                bySeq[s.seq] = (s.arr.map { $0 - base }, s.dep.map { $0 - base })
            }
            guard let firstSeq = bySeq.keys.min(), trip.stops.indices.contains(firstSeq - 1), let fp = bySeq[firstSeq] else { continue }
            let fs = trip.stops[firstSeq - 1]
            var delay = fp.arr.map { $0 - fs.arr } ?? (fp.dep! - fs.dep)
            var stops = trip.stops.enumerated().map { i, s -> TripStop in
                if let p = bySeq[i + 1] {
                    let arr = p.arr ?? (p.dep! - (s.dep - s.arr))
                    let dep = p.dep ?? max(arr, s.dep + (arr - s.arr))
                    delay = dep - s.dep
                    return TripStop(stopId: s.stopId, arr: arr, dep: dep, dist: s.dist)
                }
                return TripStop(stopId: s.stopId, arr: s.arr + delay, dep: s.dep + delay, dist: s.dist)
            }
            for i in stops.indices.dropFirst() { // keep it monotonic
                stops[i].arr = max(stops[i].arr, stops[i - 1].dep + 30)
                stops[i].dep = max(stops[i].dep, stops[i].arr)
            }
            out[trip.id] = stops
        }
        correctWithGPS(rt, &out)
        return out
    }

    /// GPS correction: project each train's GPS fix onto its track, then re-time the run it is on
    /// so the model passes that point at the GPS time, keeping the predicted arrival at the next stop.
    private func correctWithGPS(_ rt: Realtime, _ predicted: inout [String: [TripStop]]) {
        for v in rt.vehicles {
            guard var s = predicted[v.trip], let trip = tripsById[v.trip] else { continue }
            defer { predicted[v.trip] = s }
            let (d, meters) = project(onShape: trip.shape, lon: v.lon, lat: v.lat)
            if meters > 300 { continue } // too far from the track to trust
            let t = v.at - day(v.at).midnight
            if v.status == "STOPPED_AT", let seq = v.stopSeq, seq > 0 {
                if s.indices.contains(seq - 1) {
                    s[seq - 1].arr = min(s[seq - 1].arr, t)
                    s[seq - 1].dep = max(s[seq - 1].dep, t + 20)
                }
                continue
            }
            guard let i = s.indices.dropLast().first(where: { s[$0].dist <= d && d < s[$0 + 1].dist }) else { continue }
            let a = s[i], b = s[i + 1]
            if d - a.dist < 50 { s[i].dep = max(a.dep, t + 20); continue } // still at the station
            if t >= b.arr { continue }
            let q = Self.profileInverse((d - a.dist) / (b.dist - a.dist))
            s[i].dep = min((t - q * b.arr) / (1 - q), t) // departure time that puts the train at d at time t
            s[i].arr = min(s[i].arr, s[i].dep)
            for j in stride(from: i, to: 0, by: -1) where s[j - 1].dep > s[j].arr - 30 {
                s[j - 1].dep = s[j].arr - 30
                s[j - 1].arr = min(s[j - 1].arr, s[j - 1].dep)
            }
        }
    }

    /// Live timeline for a trip when live data is trusted (weight over 0.5), else nil.
    private func liveStops(_ tripId: String) -> [TripStop]? {
        liveWeight > 0.5 ? predicted[tripId] : nil
    }

    // MARK: Trains on the map

    // tripId -> last displayed distance. Small backward steps (jitter as predictions update) are
    // held, but a real correction, like live data saying a train is running late after it was drawn
    // on time, eases the train back within a second or two. Holding those put late trains minutes
    // ahead of where they really were.
    private var shown: [String: Double] = [:]
    private static let holdM = 40.0, easeBackS = 0.8
    private var lastTrainsT: Double?

    func trains(at t: Double) -> [TrainPosition] {
        let dt = lastTrainsT.map { max(0, min(0.5, t - $0)) } ?? 0
        lastTrainsT = t
        let d = day(t), services = activeServices(d), secs = d.secs
        let age = snapshotAt.map { t - $0 } ?? .infinity
        let sameDay = snapshotAt.map { day($0).ymd == d.ymd } ?? false
        // weight of live predictions: 1 while fresh, fading to 0 by staleS, 0 before the snapshot or on other days
        let w: Double = !sameDay || age < -60 ? 0 : age <= Self.freshS ? 1 : age >= Self.staleS ? 0 : 1 - (age - Self.freshS) / (Self.staleS - Self.freshS)
        liveWeight = w
        var out: [TrainPosition] = []
        for trip in data.trips where services.contains(trip.service) {
            let sched = distAt(trip.stops, secs)
            var live = w > 0 ? predicted[trip.id].flatMap { distAt($0, secs) } : nil
            // ease from the previous prediction to the new one instead of jumping
            let k = min(1, (t - blendStart) / Self.blendS)
            if k < 1, let l = live, let prev = prevPredicted?[trip.id].flatMap({ distAt($0, secs) }) { live = prev + (l - prev) * k }
            var pos: Double?
            var isLive = false
            if let l = live, let s = sched { pos = s + (l - s) * w; isLive = w > 0.5 }
            else if let l = live, w > 0.5 { pos = l; isLive = true }
            else { pos = sched }
            guard var dist = pos else { shown[trip.id] = nil; continue }
            if let was = shown[trip.id], dist < was {
                dist = was - dist < Self.holdM ? was : was - (was - dist) * min(1, dt / Self.easeBackS)
            }
            shown[trip.id] = dist
            let p = point(onShape: trip.shape, at: dist)
            out.append(TrainPosition(trip: trip, coordinate: p.coordinate, bearing: p.bearing, dist: dist, live: isLive))
        }
        out += waitingTrains(secs: secs, midnight: d.midnight, services: services, drawn: Set(out.map(\.id)))
        return out
    }

    /// A train turning around at the end of the line is on no trip while it waits, so it would
    /// vanish from the map. This shows it at the station as the trip it will run next.
    ///
    /// The data doesn't say which arriving train runs which departure, so it's a guess: the trip
    /// that last arrived there from the other way runs the first departure after it, and the
    /// train appears once that arrival has come in. With no arrival before it (the first trip of
    /// the day), it appears 15 minutes before it leaves.
    private func waitingTrains(secs: Double, midnight: Double, services: Set<String>, drawn: Set<String>) -> [TrainPosition] {
        let today = data.trips.filter { services.contains($0.service) }
        var out: [TrainPosition] = []
        for trip in today where !drawn.contains(trip.id) {
            guard let first = (liveStops(trip.id) ?? trip.stops).first, secs < first.dep, first.dep - secs < 3600 else { continue }
            let inbound = today
                .filter { $0.dir != trip.dir && $0.stops.last?.stopId == first.stopId }
                .compactMap { t in (liveStops(t.id) ?? t.stops).last.map { (id: t.id, arr: $0.arr) } }
                .filter { $0.arr <= first.dep && $0.arr > first.dep - 3600 }
                .max { $0.arr < $1.arr }
            if let inbound {
                // still on its way in, or it's running an earlier departure than this one
                if drawn.contains(inbound.id) || secs < inbound.arr { continue }
                let earlier = today.contains { o in
                    o.id != trip.id && o.dir == trip.dir && o.stops.first?.stopId == first.stopId
                        && (o.stops.first?.dep ?? 0) > inbound.arr && (o.stops.first?.dep ?? 0) < first.dep
                }
                if earlier { continue }
            } else if first.dep - secs > 900 {
                continue
            }
            let p = point(onShape: trip.shape, at: first.dist)
            out.append(TrainPosition(trip: trip, coordinate: p.coordinate, bearing: p.bearing, dist: first.dist,
                                     live: liveStops(trip.id) != nil, departsAt: midnight + first.dep))
        }
        return out
    }

    // MARK: Stations

    /// The bundled data always has stations; `init` checks.
    func nearestStation(to c: CLLocationCoordinate2D) -> (station: Station, miles: Double) {
        var best = data.stations[0], bd = Double.infinity
        for s in data.stations {
            let d = hypot((s.lon - c.longitude) * cos(c.latitude * .pi / 180), s.lat - c.latitude)
            if d < bd { bd = d; best = s }
        }
        return (best, bd * 69.1)
    }

    /// Upcoming trains that stop at this station, per direction (1 = northbound, 0 = southbound),
    /// today and the next two service days. Trains that end here are left out: you can't board them.
    /// Live predictions are used for today's trips while the live data is fresh.
    func arrivals(at stationId: String, now t: Double) -> [Int: [Arrival]] {
        let today = day(t)
        var out: [Int: [Arrival]] = [0: [], 1: []]
        for off in 0..<3 {
            let d = day(today.midnight + Double(off) * 86_400 + 43_200), services = activeServices(d)
            for trip in data.trips where services.contains(trip.service) {
                guard let i = trip.stops.firstIndex(where: { $0.stopId == stationId }), i != trip.stops.count - 1 else { continue }
                let sched = d.midnight + trip.stops[i].arr
                let p = off == 0 ? liveStops(trip.id) : nil
                let arr = p.map { d.midnight + $0[i].arr } ?? sched
                let dep = d.midnight + (p?[i].dep ?? trip.stops[i].dep)
                if dep <= t { continue }
                out[trip.dir, default: []].append(Arrival(trip: trip, arr: arr, dep: dep, sched: sched, live: p != nil, dayOffset: off))
            }
        }
        for k in out.keys { out[k]?.sort { $0.arr < $1.arr } }
        return out
    }

    /// True if no train in this direction can be boarded here (the end of the line).
    func isTerminal(_ stationId: String, dir: Int) -> Bool {
        !data.trips.contains { $0.dir == dir && $0.stops.dropLast().contains { $0.stopId == stationId } }
    }

    // MARK: Horse: trains passing the track nearest you

    func trackPoint(near c: CLLocationCoordinate2D) -> TrackPoint {
        var d: [String: Double] = [:]
        for id in shapes.keys { d[id] = project(onShape: id, lon: c.longitude, lat: c.latitude).dist }
        let p = point(onShape: lineTrip.shape, at: d[lineTrip.shape] ?? 0)
        return TrackPoint(coordinate: p.coordinate, distOnShape: d)
    }

    /// Every train that passes the point, today and the next two service days, soonest first.
    /// It stays listed ("Now") until 20 s after it goes by.
    func passes(at pt: TrackPoint, now t: Double) -> [Arrival] {
        let today = day(t)
        var out: [Arrival] = []
        for off in 0..<3 {
            let d = day(today.midnight + Double(off) * 86_400 + 43_200), services = activeServices(d)
            for trip in data.trips where services.contains(trip.service) {
                guard let dc = pt.distOnShape[trip.shape], let s = timeAtDist(trip.stops, dc) else { continue }
                let live = off == 0 ? liveStops(trip.id).flatMap { timeAtDist($0, dc) } : nil
                let arr = d.midnight + (live ?? s)
                if arr <= t - 20 { continue }
                out.append(Arrival(trip: trip, arr: arr, dep: arr, sched: d.midnight + s, live: live != nil, dayOffset: off))
            }
        }
        return out.sorted { $0.arr < $1.arr }
    }

    /// The next of today's trains to reach a point on the track (given as meters along each shape).
    func nextTrain(reaching distOnShape: [String: Double], now t: Double) -> Trip? {
        let d = day(t), services = activeServices(d)
        var best: (trip: Trip, at: Double)?
        for trip in data.trips where services.contains(trip.service) {
            guard let dc = distOnShape[trip.shape], let at = timeAtDist(liveStops(trip.id) ?? trip.stops, dc),
                  at > d.secs, at < best?.at ?? .infinity else { continue }
            best = (trip, at)
        }
        return best?.trip
    }

    // MARK: Driver: level crossings

    // Gate model, per train, per crossing, from SMART's 2022 San Rafael gate-down study
    // (580+ activations at 2nd St): one train holds the gates 52 s on average, 35 s at least.
    //   Gates go down 30 s before the train reaches the crossing and up 22 s after.
    //   Station rule: for a crossing within 250 m past a platform, in the direction of travel, a
    //   dwell longer than the normal 60 s keeps the gates down that much longer.
    //   Uncertainty: the window widens as live data ages, and more for timetable-only estimates.
    // Street heat: red from 60 s before the gates drop until they're up, then fades over 3 min
    // (traffic still backed up); yellow when a train is within 5 minutes.
    private static let gateLeadS = 30.0, gateLiftS = 22.0, stationM = 250.0, normalDwellS = 60.0
    private static let redLeadS = 60.0, yellowS = 5.0 * 60
    private static let marginPerMinS = 4.0, marginMaxS = 60.0, marginScheduleS = 45.0
    static let fadeS = 3.0 * 60, armM = 250.0
    private static let pieceM = 20.0

    func makeCrossings() -> [CrossingState] {
        data.crossings.map { c in
            var d: [String: Double] = [:]
            for id in shapes.keys { d[id] = project(onShape: id, lon: c.lon, lat: c.lat).dist }
            // cut each street arm into short pieces that know their distance from the crossing
            var pieces: [(coords: [CLLocationCoordinate2D], mid: Double)] = []
            for arm in c.arms.map({ $0.filter { $0.count >= 2 } }) where arm.count > 1 {
                var dist = 0.0
                var cur = CLLocationCoordinate2D(latitude: arm[0][1], longitude: arm[0][0])
                for i in 1..<arm.count {
                    let a = arm[i - 1], b = arm[i]
                    let len = hypot((b[0] - a[0]) * 111_320 * cos(a[1] * .pi / 180), (b[1] - a[1]) * 110_540)
                    let n = max(1, Int((len / Self.pieceM).rounded(.up)))
                    for k in 1...n {
                        let f = Double(k) / Double(n)
                        let p = CLLocationCoordinate2D(latitude: a[1] + (b[1] - a[1]) * f, longitude: a[0] + (b[0] - a[0]) * f)
                        dist += len / Double(n)
                        if dist - len / Double(n) < Self.armM { pieces.append(([cur, p], dist - len / Double(n) / 2)) }
                        cur = p
                    }
                }
            }
            return CrossingState(crossing: c, distOnShape: d, pieces: pieces)
        }
    }

    /// When a train on this timeline reaches the crossing at `dc`, and when the gates go down and
    /// come back up for it, with the uncertainty margin. Seconds since the service day's midnight.
    private func gateWindow(_ stops: [TripStop], _ dc: Double, live: Bool, ageMin: Double) -> (at: Double, down: Double, up: Double)? {
        guard let at = timeAtDist(stops, dc) else { return nil }
        var down = at - Self.gateLeadS
        // station rule: platform just before this crossing (not the trip's first stop); dwell beyond normal adds on
        for i in stops.indices.dropFirst().dropLast() where stops[i].dist < dc && dc <= stops[i].dist + Self.stationM {
            down -= max(0, stops[i].dep - stops[i].arr - Self.normalDwellS)
        }
        let margin = live ? min(Self.marginMaxS, Self.marginPerMinS * ageMin) : Self.marginScheduleS
        return (at, down - margin, at + Self.gateLiftS + margin)
    }

    func update(_ crossings: inout [CrossingState], now t: Double) {
        let today = day(t), services = activeServices(today), secs = today.secs
        let ageMin = snapshotAt.map { max(0, (t - $0) / 60) } ?? .infinity
        for ci in crossings.indices {
            let c = crossings[ci]
            var next = Double.infinity, nextLive = false, since = Double.infinity
            var redNow = false, blockedNow = false, nextRed = Double.infinity
            // which train each kind of heat comes from: the one that cleared last, the soonest of
            // those turning it red now, and the next one to turn it red
            var clearedCause, redCause, nextRedCause: (trip: String, at: Double)?
            for trip in data.trips where services.contains(trip.service) {
                let live = liveStops(trip.id)
                guard let dc = c.distOnShape[trip.shape], let g = gateWindow(live ?? trip.stops, dc, live: live != nil, ageMin: ageMin) else { continue }
                let at = g.at
                let gd = g.down - secs, gu = g.up - secs // gates down / up, from now
                let rs = gd - Self.redLeadS // red starts, from now
                if gu <= 0 { // this train has cleared
                    if -gu < since { since = -gu; clearedCause = (trip.id, at - secs) }
                    continue
                }
                if rs <= 0 {
                    redNow = true
                    if at - secs < redCause?.at ?? .infinity { redCause = (trip.id, at - secs) }
                } else if rs < nextRed {
                    nextRed = rs
                    nextRedCause = (trip.id, at - secs)
                }
                if gd <= 0 { blockedNow = true }
                if at - secs < next { next = max(0, at - secs); nextLive = live != nil }
            }
            // Every train counts, both directions: the strongest signal wins, so when two trains pass
            // close together the street stays red from the first until well after the second clears.
            let residual = since < Self.fadeS ? 1 - since / Self.fadeS : 0 // traffic still backed up
            let yellow = nextRed <= Self.yellowS - Self.redLeadS - Self.gateLeadS
            let heat: CrossingState.Heat? = redNow ? .red(1)
                : residual >= 0.5 ? .red(residual)
                : yellow ? .yellow
                : residual > 0 ? .red(residual)
                : nil
            crossings[ci].heat = heat
            crossings[ci].cause = redNow ? redCause
                : residual >= 0.5 ? clearedCause
                : yellow ? nextRedCause
                : residual > 0 ? clearedCause
                : nil
            crossings[ci].next = next
            crossings[ci].nextLive = nextLive
            crossings[ci].residual = residual
            crossings[ci].redNow = redNow
            crossings[ci].blockedNow = blockedNow
        }
    }
}
