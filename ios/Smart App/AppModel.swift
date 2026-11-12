import Foundation
import CoreLocation
import Observation

enum Mode: String, CaseIterable, Identifiable {
    case rider, driver, horse
    var id: Self { self }
}

/// Something tappable on the map.
enum MapItem: Hashable {
    case station(String)
    case crossing(String)
}

/// A request to move the camera so all `points` are in view.
struct FramingRequest: Equatable {
    let id = UUID()
    /// The tab this framing is for.
    let mode: Mode
    let points: [CLLocationCoordinate2D]
    /// The closest the camera may zoom, as a web-map zoom level (nil = fit the points, however close).
    let maxZoom: Double?
    /// The whole line, seen from far out: tighter margins, and the tilt MapKit allows that far out.
    var overview = false

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

@Observable
final class AppModel {
    /// Live data from the Cloudflare Worker, which holds the 511 key and caps 511 usage server-side.
    /// Polling it never raises 511 usage: the Worker refreshes GPS at most every 2 minutes.
    static let liveURL = URL(string: "https://smart-trains.smart-trains-worker.workers.dev/realtime")!
    private static let pollInterval: Duration = .seconds(30)
    /// Stop polling after 10 minutes without interaction.
    private static let idleTimeout: TimeInterval = 10 * 60
    /// More than this far from every station, "nearest station" means nothing.
    static let farMiles = 30.0
    /// A fix less accurate than this (an IP-based guess) never moves the map.
    private static let roughMeters = 1500.0

    let engine: TrainEngine
    let location = LocationProvider()

    private(set) var mode: Mode
    private(set) var trains: [TrainPosition] = []
    private(set) var crossings: [CrossingState]
    /// Wall clock, refreshed every second, so the cards count down.
    private(set) var now = Date.now.timeIntervalSince1970
    private(set) var trackPoint: TrackPoint?
    private(set) var selectedStationId: String?
    private(set) var selectedDir: Int?
    private(set) var selectedCrossingId: String?
    private(set) var framing: FramingRequest?

    /// Set once you've moved or tapped the map, the card or a tab since the last locate.
    @ObservationIgnored private var userActed = false
    @ObservationIgnored private var framedAt: CLLocationCoordinate2D?
    /// Where we are in a locate: the first precise fix frames, then one refined fix may re-frame
    /// (if it lands more than 300 m away). The camera moves once per locate, not once per fix.
    private enum LocateStage { case idle, waitingForFix, refining(until: Date) }
    @ObservationIgnored private var locateStage = LocateStage.idle
    @ObservationIgnored private var activeUntil = Date.now.addingTimeInterval(idleTimeout)
    @ObservationIgnored private var isActive = true
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(data: TransitData = .loadBundled()) {
        engine = TrainEngine(data: data)
        crossings = engine.makeCrossings()
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .rider
        location.onFix = { [weak self] in self?.handleFix($0) }
        trains = engine.trains(at: now)
        engine.update(&crossings, now: now)
    }

    var me: CLLocationCoordinate2D? { location.location?.coordinate }

    // MARK: Lifecycle

    func start() {
        isActive = true
        // pollLoop polls straight away, so just reset the idle timer here
        activeUntil = Date.now.addingTimeInterval(Self.idleTimeout)
        location.start()
        if tickTask == nil { tickTask = Task { [weak self] in await self?.tickLoop() } }
        if pollTask == nil { pollTask = Task { [weak self] in await self?.pollLoop() } }
    }

    func stop() {
        isActive = false
        tickTask?.cancel(); tickTask = nil
        pollTask?.cancel(); pollTask = nil
        location.stop()
    }

    private func tickLoop() async {
        var lastSecond = 0.0
        while !Task.isCancelled {
            let t = Date.now.timeIntervalSince1970
            trains = engine.trains(at: t)
            if t - lastSecond >= 1 {
                lastSecond = t
                now = t
                engine.update(&crossings, now: t)
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await poll()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    private func poll() async {
        guard isActive, Date.now < activeUntil else { return }
        do {
            var request = URLRequest(url: Self.liveURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (bytes, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let rt = try JSONDecoder().decode(Realtime.self, from: bytes)
            engine.apply(rt, now: Date.now.timeIntervalSince1970)
        } catch {
            // Keep showing the last snapshot; trains fade to estimates as it ages.
        }
    }

    /// Any interaction keeps live data polling for another 10 minutes.
    func wake() {
        let wasIdle = Date.now >= activeUntil
        activeUntil = Date.now.addingTimeInterval(Self.idleTimeout)
        if wasIdle { Task { await poll() } }
    }

    // MARK: Location

    /// Finds you and frames the view around you. The camera moves once per locate, not once per fix.
    func locate() {
        wake()
        userActed = false
        framedAt = nil
        locateStage = .waitingForFix
        location.start()
        if let loc = location.location { handleFix(loc) }
    }

    private func handleFix(_ loc: CLLocation) {
        trackPoint = engine.trackPoint(near: loc.coordinate)
        // A fix less accurate than 1.5 km (an IP-based guess) never moves the map.
        let precise = loc.horizontalAccuracy >= 0 && loc.horizontalAccuracy <= Self.roughMeters
        guard precise else { return }
        switch locateStage {
        case .idle:
            return
        case .waitingForFix:
            // the refined fix that follows may re-frame, briefly
            locateStage = .refining(until: Date.now.addingTimeInterval(15))
        case .refining(let until):
            guard Date.now < until else { locateStage = .idle; return }
            if let f = framedAt, CLLocation(latitude: f.latitude, longitude: f.longitude).distance(from: loc) <= 300 { return }
            locateStage = .idle // re-frame at most once more
        }
        guard !userActed else { return }
        framedAt = loc.coordinate
        frameView()
    }

    // MARK: Interaction

    func setMode(_ m: Mode) {
        // Tapping the tab you're on puts its view back the way it starts: nearest station or
        // crossing, no picked direction.
        guard m != mode else { return resetView() }
        userActed = true
        wake()
        mode = m
        UserDefaults.standard.set(m.rawValue, forKey: "mode")
        if m != .rider { selectedStationId = nil; selectedDir = nil }
        if m != .driver { selectedCrossingId = nil }
        frameView()
    }

    private func resetView() {
        wake()
        selectedStationId = nil
        selectedDir = nil
        selectedCrossingId = nil
        frameView()
    }

    /// You moved the map yourself: stop re-framing on location fixes.
    func userMovedMap() {
        userActed = true
        wake()
    }

    /// Tap a station (Rider) or crossing (Driver) to see its trains; tap it again, or elsewhere,
    /// to go back to the one nearest you. `onFeature` is true when the tap landed on a station or crossing.
    func select(_ item: MapItem?, onFeature: Bool) {
        userActed = true
        wake()
        switch mode {
        case .rider:
            let hadDir = selectedDir != nil
            if case .station(let id) = item, id != selectedStationId { selectedStationId = id } else { selectedStationId = nil }
            selectedDir = nil // a tap on the map also cancels a picked direction
            if hadDir && !onFeature { frameView() } // back to framing both trains
        case .driver:
            if case .crossing(let id) = item, id != selectedCrossingId { selectedCrossingId = id } else { selectedCrossingId = nil }
        case .horse:
            break
        }
    }

    /// Any tap on the map. In Rider it cancels a picked direction and goes back to both trains.
    func mapTapped() {
        wake()
        guard mode == .rider else { return }
        userActed = true
        guard selectedDir != nil else { return }
        Task {
            // let a station selection from the same tap land first
            try? await Task.sleep(for: .milliseconds(150))
            guard selectedDir != nil else { return }
            selectedDir = nil
            frameView()
        }
    }

    /// Tap a direction to frame the station and that direction's next train; tap it again to go back to both.
    func pickDirection(_ dir: Int) {
        userActed = true
        wake()
        selectedDir = selectedDir == dir ? nil : dir
        frameView()
    }

    // MARK: Rider

    var riderStation: Station? {
        if let id = selectedStationId { return engine.stationsById[id] }
        guard let me else { return nil }
        let n = engine.nearestStation(to: me)
        return n.miles < Self.farMiles ? n.station : nil
    }

    /// Rider: true for a train that has left your station behind, or never stops there.
    /// A train standing at the platform still counts as arriving.
    func isLeavingRiderStation(_ t: TrainPosition) -> Bool {
        guard mode == .rider, let st = riderStation else { return false }
        guard let stop = t.trip.stops.first(where: { $0.stopId == st.id }) else { return true }
        return t.dist > stop.dist + 30
    }

    /// With a direction picked, the train it shows (others are dimmed).
    var focusTripId: String? {
        guard mode == .rider, let dir = selectedDir, let st = riderStation,
              let n = engine.arrivals(at: st.id, now: now)[dir]?.first, n.dayOffset == 0 else { return nil }
        return n.trip.id
    }

    // MARK: Driver

    /// The crossing whose next traffic event is labeled: the one you tapped, or else the one nearest you.
    var labeledCrossingId: String? {
        if let id = selectedCrossingId { return id }
        guard let me else { return nil }
        return nearestCrossing(to: me)?.id
    }

    /// The crossing in the card: the one you tapped, or else the one nearest you (if you're near the line).
    var driverCrossing: CrossingState? {
        if let id = selectedCrossingId { return crossings.first { $0.id == id } }
        guard let me, engine.nearestStation(to: me).miles < Self.farMiles else { return nil }
        return nearestCrossing(to: me)
    }

    func nearestCrossing(to c: CLLocationCoordinate2D) -> CrossingState? {
        crossings.min { distanceSquared($0.coordinate, c) < distanceSquared($1.coordinate, c) }
    }

    /// The next train to reach the crossing nearest you, when it isn't on the map yet (not even
    /// waiting at its first station, e.g. the first trip of the day): where it leaves from, and when.
    var driverPendingDeparture: (station: Station, departs: Double)? {
        guard mode == .driver, let me, engine.nearestStation(to: me).miles < Self.farMiles,
              let c = nearestCrossing(to: me), let trip = engine.nextTrain(reaching: c.distOnShape, now: now),
              train(trip.id) == nil, let first = trip.stops.first, let o = engine.stationsById[first.stopId] else { return nil }
        return (o, engine.day(now).midnight + first.dep)
    }

    /// "Departs in 12 min", or the clock time once it's an hour or more away.
    func departureText(_ unix: Double) -> String {
        let n = unix - now
        if n < 3600 { return String(localized: "Departs in \(max(1, Int((n / 60).rounded(.up)))) min") }
        let at = Date(timeIntervalSince1970: unix).formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: engine.timeZone))
        return String(localized: "Departs \(at)")
    }

    func label(for c: CrossingState) -> (title: String, subtitle: String?) {
        let n = c.next
        let title: String
        if c.blockedNow { title = String(localized: "Blocked now") }
        else if c.residual >= 0.5 && !c.redNow { title = String(localized: "Traffic clearing") }
        else if n < 3600 { title = String(localized: "Train in \(max(1, Int((n / 60).rounded(.up)))) min") }
        else if n < .infinity {
            let at = Date(timeIntervalSince1970: now + n).formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: engine.timeZone))
            title = String(localized: "Next train \(at)")
        } else { title = String(localized: "No more trains today") }
        return (title, n < .infinity && !c.nextLive ? String(localized: "scheduled") : nil)
    }

    // MARK: Framing

    private var wholeLine: [CLLocationCoordinate2D] {
        let lats = engine.routeCoordinates.map(\.latitude), lons = engine.routeCoordinates.map(\.longitude)
        guard let s = lats.min(), let n = lats.max(), let w = lons.min(), let e = lons.max() else { return [] }
        return [.init(latitude: s, longitude: w), .init(latitude: n, longitude: e)]
    }

    var initialFraming: FramingRequest { FramingRequest(mode: mode, points: wholeLine, maxZoom: nil, overview: true) }

    private func coordinate(of s: Station) -> CLLocationCoordinate2D { .init(latitude: s.lat, longitude: s.lon) }

    private func train(_ tripId: String) -> TrainPosition? { trains.first { $0.trip.id == tripId } }

    private func frame(_ points: [CLLocationCoordinate2D], maxZoom: Double? = nil) {
        guard !points.isEmpty else { return }
        framing = FramingRequest(mode: mode, points: points, maxZoom: maxZoom)
    }

    private func frameWholeLine() {
        framing = FramingRequest(mode: mode, points: wholeLine, maxZoom: nil, overview: true)
    }

    func frameView() {
        switch mode {
        case .rider: frameRider()
        case .horse: frameHorse()
        case .driver: frameDriver()
        }
    }

    /// Rider: your station and the next northbound and southbound trains to reach it (or, for one
    /// that hasn't set off yet, the station it leaves from). A picked direction frames just the
    /// station and its train. You're left out: what matters is what's happening at your stop.
    private func frameRider() {
        guard let st = riderStation else {
            // far from every station: the whole line
            if me != nil { frameWholeLine() }
            return
        }
        var pts = [coordinate(of: st)]
        let a = engine.arrivals(at: st.id, now: now)
        for d in selectedDir.map({ [$0] }) ?? [1, 0] {
            guard let n = a[d]?.first else { continue }
            if n.dayOffset == 0, let tr = train(n.trip.id) { pts.append(tr.coordinate) }
            // a train that hasn't set off yet: show where it will leave from (today's trains, or any picked one)
            else if n.dayOffset == 0 || selectedDir != nil, let o = n.trip.stops.first.flatMap({ engine.stationsById[$0.stopId] }) { pts.append(coordinate(of: o)) }
        }
        frame(pts)
    }

    /// Horse: you and the next train to pass the track near you, either direction. If it hasn't set
    /// off yet, the station it leaves from; with no more trains today, the track point.
    private func frameHorse() {
        guard let me, let tp = trackPoint else { return }
        if engine.nearestStation(to: me).miles >= Self.farMiles { return frameWholeLine() }
        let n = engine.passes(at: tp, now: now).first { $0.dayOffset == 0 && $0.arr > now }
        let target = n.flatMap { train($0.trip.id)?.coordinate }
            ?? n.flatMap { $0.trip.stops.first.flatMap { engine.stationsById[$0.stopId] } }.map(coordinate(of:))
            ?? tp.coordinate
        frame([me, target])
    }

    /// Driver: you, the level crossing nearest you, and the next train to reach that crossing.
    /// If that train hasn't set off yet, the station it leaves from; with no more trains today,
    /// just you and the crossing.
    private func frameDriver() {
        guard let me else { return }
        guard engine.nearestStation(to: me).miles < Self.farMiles else { return frameWholeLine() }
        var pts = [me]
        if let c = nearestCrossing(to: me) {
            pts.append(c.coordinate)
            if let trip = engine.nextTrain(reaching: c.distOnShape, now: now) {
                if let tr = train(trip.id) { pts.append(tr.coordinate) }
                else if let o = trip.stops.first.flatMap({ engine.stationsById[$0.stopId] }) { pts.append(coordinate(of: o)) }
            }
        }
        frame(pts)
    }

    private func distanceSquared(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let dx = (a.longitude - b.longitude) * cos(b.latitude * .pi / 180), dy = a.latitude - b.latitude
        return dx * dx + dy * dy
    }
}
