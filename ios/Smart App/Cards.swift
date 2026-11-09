import SwiftUI

// The card at the bottom of Rider and Horse: the next trains, big and glanceable.

/// Clock times in the SMART time zone, whatever zone the phone is in.
struct ClockFormatter {
    let engine: TrainEngine

    func time(_ unix: Double) -> String {
        Date(timeIntervalSince1970: unix).formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: engine.timeZone))
    }

    /// Adds the weekday when it isn't today ("Sat 6:12 AM").
    func time(_ unix: Double, withDayFrom now: Double) -> String {
        guard engine.day(unix).ymd != engine.day(now).ymd else { return time(unix) }
        let day = Date(timeIntervalSince1970: unix).formatted(Date.FormatStyle(timeZone: engine.timeZone).weekday(.abbreviated))
        return "\(day) \(time(unix))"
    }
}

struct CardEyebrow: View {
    let text: LocalizedStringKey
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .textCase(.uppercase)
            // SMART orange marks labels, never data, so it can't be mistaken for a status.
            .foregroundStyle(Color.brandOrange)
    }
}

/// A card that scrolls only when its content doesn't fit (large Dynamic Type sizes). When its
/// subject changes (another station, crossing or spot), the card resizes smoothly and its
/// content cross-fades, rather than snapping.
struct CardContainer<Subject: Equatable, Content: View>: View {
    let subject: Subject
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ViewThatFits(in: .vertical) {
            inner
            ScrollView { inner }
                .scrollBounceBehavior(.basedOnSize)
                // Scrolled content stays inside the card rather than drawing over the map.
                .clipShape(.rect(cornerRadius: 28))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandSurface(in: .rect(cornerRadius: 28))
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35), value: subject)
    }

    private var inner: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Rider

struct RiderCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        CardContainer(subject: model.riderStation?.id) {
            if let st = model.riderStation {
                let a = model.engine.arrivals(at: st.id, now: model.now)
                CardEyebrow(text: model.selectedStationId != nil ? "Station" : "Nearest station")
                Text(st.name)
                    .font(.title.bold())
                    .padding(.top, 1)
                    .padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
                DirectionRow(name: "Northbound", dir: 1, stationId: st.id, list: a[1] ?? [])
                DirectionRow(name: "Southbound", dir: 0, stationId: st.id, list: a[0] ?? [])
            } else {
                CardEyebrow(text: "Next trains")
                Text("Find your station")
                    .font(.title.bold())
                    .padding(.top, 1)
                Text(model.me != nil ? "You’re not near a SMART station. Tap one on the map." : "Share your location, or tap a station on the map.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
            }
        }
    }
}

private struct DirectionRow: View {
    @Environment(AppModel.self) private var model
    let name: LocalizedStringKey
    let dir: Int
    let stationId: String
    let list: [Arrival]

    var body: some View {
        if let next = list.first {
            let selected = model.selectedDir == dir
            Button { model.pickDirection(dir) } label: {
                content(next: next, selected: selected)
            }
            .buttonStyle(.plain)
            .opacity(model.selectedDir != nil && !selected ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.2), value: model.selectedDir)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(dir == 1 ? "Shows the next northbound train on the map" : "Shows the next southbound train on the map")
        } else if !model.engine.isTerminal(stationId, dir: dir) {
            // At the end of the line there's no row for the direction you can't go.
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                Text(name).font(.headline).padding(.top, 8)
                Text("No trains in the next two days")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 10)
            }
        }
    }

    private func content(next: Arrival, selected: Bool) -> some View {
        let clock = ClockFormatter(engine: model.engine)
        let now = model.now
        // The next train (live where we have it), then the two after it by the timetable.
        let later = list.dropFirst().filter { $0.sched > next.sched }.sorted { $0.sched < $1.sched }.prefix(2)

        return VStack(spacing: 0) {
            Divider()
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.headline)
                        .foregroundStyle(selected ? Color.accent : .primary)
                    Text("to \(next.trip.headsign)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if !later.isEmpty {
                        // non-breaking spaces, so a line only wraps between times
                        Text("Then \(later.map { clock.time($0.sched, withDayFrom: now).replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: " · "))")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
                NextTrainTime(arrival: next, now: now, clock: clock)
            }
            .padding(.vertical, 11)
            .contentShape(.rect)
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }
}

/// The big wait for a train ("4 min", "Now", or its clock time past an hour), with whether
/// it's live or scheduled, its clock time, and how late it's running.
private struct NextTrainTime: View {
    let arrival: Arrival
    let now: Double
    let clock: ClockFormatter
    /// Driver: what the gates are doing, shown in place of the countdown while it matters.
    var status: GateStatus? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let s = arrival.arr - now
        let late = arrival.live ? Int(((arrival.arr - arrival.sched) / 60).rounded()) : 0
        VStack(alignment: .trailing, spacing: 4) {
            ZStack(alignment: .trailing) {
                if let status {
                    Text(status.text)
                        .font(.title3.bold())
                        .foregroundStyle(status.color)
                        .multilineTextAlignment(.trailing)
                        // Each change of state morphs the words.
                        .contentTransition(.interpolate)
                        .transition(.blurReplace)
                } else {
                    bigTime(seconds: s)
                        // The minutes roll down as they tick, and "Now" fades in.
                        .contentTransition(.numericText(countsDown: true))
                        .transition(.blurReplace)
                }
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: Countdown(seconds: s, clockTime: arrival.arr))
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.35), value: status)
            HStack(spacing: 0) {
                if arrival.live {
                    Label("Live", systemImage: "circle.fill")
                        .labelStyle(LiveLabelStyle())
                        .foregroundStyle(Color.accent)
                        .fontWeight(.semibold)
                } else {
                    Text("Scheduled")
                }
                if s > 30 && s < 3600 { Text(" · \(clock.time(arrival.arr))") }
                if late >= 2 {
                    Text(" · ")
                    Text("\(late) min late").foregroundStyle(Color.late).fontWeight(.semibold)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private func bigTime(seconds s: Double) -> some View {
        if s <= 30 {
            Text("Now").font(.largeTitle.bold())
        } else if s < 3600 {
            let minutes = Int((s / 60).rounded(.up))
            Text("\(Text("\(minutes)").font(.largeTitle.bold())) \(Text("min").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary))")
                .accessibilityLabel("\(minutes) minutes")
        } else {
            Text(clock.time(arrival.arr, withDayFrom: now)).font(.title2.bold())
        }
    }
}

/// What a big countdown shows ("Now", whole minutes, or, past an hour, a clock time if it
/// switches to one), so it animates only when that changes, not every second.
private struct Countdown: Equatable {
    let shown: Double

    init(seconds s: Double, clockTime unix: Double? = nil) {
        if s <= 30 { shown = -1 }
        else if let unix, s >= 3600 { shown = unix }
        else { shown = (s / 60).rounded(.up) }
    }
}

/// A small dot before "Live".
private struct LiveLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.font(.system(size: 6)).accessibilityHidden(true)
            configuration.title
        }
    }
}

// MARK: - Driver

/// The level crossing nearest you (or the one you tapped): whether the gates are down, and
/// when the next train reaches it.
struct DriverCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        CardContainer(subject: model.driverCrossing?.id) {
            if let c = model.driverCrossing {
                CardEyebrow(text: model.selectedCrossingId != nil ? "Crossing" : "Nearest crossing")
                Text(c.crossing.street ?? String(localized: "Level crossing"))
                    .font(.title.bold())
                    .padding(.top, 1)
                    .accessibilityAddTraits(.isHeader)
                if let town = c.crossing.city {
                    Text(town)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                NextTrains(state: c)
                    .padding(.top, 10)
            } else {
                CardEyebrow(text: "Next trains")
                Text("Find your crossing")
                    .font(.title.bold())
                    .padding(.top, 1)
                Text(model.me != nil ? "You’re not near a SMART crossing. Tap one on the map." : "Share your location, or tap a crossing on the map.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
            }
        }
    }
}

/// What the gates are doing, colored like the crossing's dot on the map. Nil while they're clear.
private struct GateStatus: Equatable {
    let text: LocalizedStringKey
    let color: Color

    // Lighter than the map's heat colors, to read on the green card.
    private static let red = Color(red: 1, green: 0x8a / 255, blue: 0x80 / 255)
    private static let yellow = Color(red: 0xf5 / 255, green: 0xc8 / 255, blue: 0x3a / 255)

    init?(_ state: CrossingState) {
        if state.blockedNow { (text, color) = ("Gates down", Self.red) }
        else if state.redNow { (text, color) = ("Gates closing", Self.red) }
        else if state.residual >= 0.5 { (text, color) = ("Traffic clearing", Self.red) }
        else if state.heat == .yellow { (text, color) = ("Train approaching", Self.yellow) }
        else { return nil }
    }
}

/// The next train to reach the crossing, either direction, and the two after it.
private struct NextTrains: View {
    @Environment(AppModel.self) private var model
    let state: CrossingState

    var body: some View {
        let point = TrackPoint(coordinate: state.coordinate, distOnShape: state.distOnShape)
        let list = model.engine.passes(at: point, now: model.now)
        if let next = list.first {
            let clock = ClockFormatter(engine: model.engine)
            let now = model.now
            let later = list.dropFirst().prefix(2)
            VStack(spacing: 0) {
                Divider()
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(next.trip.dir == 1 ? "Northbound" : "Southbound")
                            .font(.headline)
                        Text("to \(next.trip.headsign)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if !later.isEmpty {
                            // non-breaking spaces, so a line only wraps between times
                            Text("Then \(later.map { clock.time($0.arr, withDayFrom: now).replacingOccurrences(of: " ", with: "\u{00A0}") }.joined(separator: " · "))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }
                    Spacer(minLength: 0)
                    NextTrainTime(arrival: next, now: now, clock: clock, status: GateStatus(state))
                }
                .padding(.vertical, 11)
            }
            .monospacedDigit()
            .accessibilityElement(children: .combine)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                Text("No trains in the next two days")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }
        }
    }
}

// MARK: - Horse

/// The next three trains to pass the bit of track nearest you, whichever way they're going.
/// Nothing on it can be tapped.
struct HorseCard: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CardContainer(subject: model.trackPoint != nil) {
            if let tp = model.trackPoint {
                let next = Array(model.engine.passes(at: tp, now: model.now).prefix(3))
                if next.isEmpty {
                    Text("No trains in the next two days")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 0) {
                        ForEach(Array(next.enumerated()), id: \.offset) { i, x in
                            if i > 0 { Divider() }
                            row(index: i, pass: x)
                        }
                    }
                }
            } else {
                CardEyebrow(text: "Next trains")
                Text("Find your location")
                    .font(.title.bold())
                    .padding(.top, 1)
                Text("Share your location to see when trains pass the track nearest you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
            }
        }
    }

    private func row(index: Int, pass: Arrival) -> some View {
        GridRow {
            Text("\(index + 1).")
                .font(.headline)
                .foregroundStyle(.secondary)
            wait(pass.arr - model.now)
            Text(pass.trip.dir == 1 ? "Northbound" : "Southbound")
                .font(.title3.weight(.semibold))
                .gridColumnAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .monospacedDigit()
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    /// "Now" from 30 s before a train passes until 20 s after; "2m"; past an hour, "1h 15m".
    /// The minutes roll down as they tick.
    private func wait(_ sec: Double) -> some View {
        waitText(sec)
            .contentTransition(.numericText(countsDown: true))
            .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: Countdown(seconds: sec))
    }

    @ViewBuilder
    private func waitText(_ sec: Double) -> some View {
        let big = Font.title.bold(), unit = Font.subheadline.weight(.semibold)
        if sec <= 30 {
            Text("Now").font(big)
        } else {
            let m = Int((sec / 60).rounded(.up))
            if m < 60 {
                Text("\(Text("\(m)").font(big))\(Text("m").font(unit).foregroundStyle(.secondary))")
                    .accessibilityLabel("\(m) minutes")
            } else {
                Text("\(Text("\(m / 60)").font(big))\(Text("h").font(unit).foregroundStyle(.secondary)) \(Text("\(m % 60)").font(big))\(Text("m").font(unit).foregroundStyle(.secondary))")
                    .accessibilityLabel("\(m / 60) hours \(m % 60) minutes")
            }
        }
    }
}
