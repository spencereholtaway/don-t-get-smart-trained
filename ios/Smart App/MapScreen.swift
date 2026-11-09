import SwiftUI
import MapKit

/// One tab: a full-bleed tilted map with live trains, plus the card and map buttons for its mode.
struct MapScreen: View {
    let mode: Mode
    @Environment(AppModel.self) private var model
    @State private var position: MapCameraPosition = .automatic
    /// The camera's rotation and tilt, read only by the train arrows, so turning the map
    /// re-renders them and not the whole map.
    @State private var cameraAngle = CameraAngle()
    /// The framing last applied, so one request isn't applied twice, and so it can be fitted
    /// again when the layout changes.
    @State private var appliedFramingId: UUID?
    @State private var lastFraming: FramingRequest?
    @State private var fitter = CameraFitter()
    @State private var mapFrame = CGRect.zero
    /// The map's safe area, in global coordinates (the map itself runs under the bars).
    @State private var safeFrame = CGRect.zero
    @State private var cardFrame = CGRect.zero
    /// iPhone Duo's fold, in global coordinates, while the inner display is folded across its middle.
    @State private var foldFrame: CGRect?
    /// Open like a laptop (at least 70°): the bottom half lies flat as the map and the top half
    /// stands up as an arrivals board. Less open, it's in someone's hand, and the card stays at
    /// the bottom as on any phone.
    @State private var isLaptopPose = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showAbout = false
    @State private var showLocationHelp = false
    @State private var hasFramed = false
    /// The last framing, until the camera settles and we know the pitch MapKit allowed.
    @State private var pendingFraming: (request: FramingRequest, pitch: Double)?
    /// The tilt MapKit allowed for the whole-line view; asked for directly next time.
    @State private var allowedPitch = CameraFitter.pitch

    @Namespace private var mapScope

    private var isCurrent: Bool { model.mode == mode }

    var body: some View {
        NavigationStack {
            // The map always fills the screen: it's the app's content, folded or not. The card
            // floats over it, placed for the screen's shape and, on iPhone Duo, around the fold.
            map
                .overlay { cardLayer }
            // The map's buttons are toolbar items, so the system places them: along the top on most
            // iPhones, and on the side on iPhone Duo.
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button("Where the Data Comes From", systemImage: "info") { showAbout = true }
                }
                ToolbarItem(placement: .primaryAction) { locateButton }
                    .visibilityPriority(.high)
            }
        }
        // Folding, unfolding, rotating or resizing moves the card and the map: frame again for the
        // new clear area once the change settles.
        .modifier(HingeReader(isLaptopPose: $isLaptopPose))
        .task(id: LayoutKey(map: mapFrame, safe: safeFrame, card: cardFrame, fold: foldFrame, laptop: isLaptopPose)) {
            guard isCurrent, let f = lastFraming else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            apply(f, animated: true, force: true)
        }
        .onChange(of: model.framing) { _, f in
            guard isCurrent, let f, f.mode == mode else { return }
            apply(f, animated: true)
        }
        .onAppear {
            // A framing made for this tab (e.g. on switching to it); else, the first time it shows,
            // the whole line until we know where you are. Another tab's framing is never reused.
            if let f = model.framing, f.mode == mode { apply(f, animated: hasFramed) }
            else if !hasFramed { apply(model.initialFraming, animated: false) }
            hasFramed = true
        }
        .sheet(isPresented: $showAbout) { AboutView() }
        .alert("Location is off", isPresented: $showLocationHelp) {
            #if os(iOS)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            #endif
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("To see your nearest station, crossing or bit of track, allow location access in Settings.")
        }
    }

    /// The map, full bleed under the bars, with the compass inside the safe area.
    private var map: some View {
        MapReader { proxy in
            Map(position: $position, selection: selection, scope: mapScope) {
                mapContent
            }
            .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
            // The map runs under the status bar, so its compass is placed by hand, inside the safe area.
            .mapControls {}
            .onMapCameraChange(frequency: .continuous) { ctx in
                cameraAngle.update(ctx.camera)
            }
            .onMapCameraChange(frequency: .onEnd) { ctx in
                cameraAngle.update(ctx.camera)
                fitter.calibrate(camera: ctx.camera, proxy: proxy)
                // MapKit tilts less than asked when zoomed out; fit again for the tilt it used.
                if let p = pendingFraming {
                    pendingFraming = nil
                    if abs(ctx.camera.pitch - p.pitch) > 2 {
                        if p.request.overview { allowedPitch = ctx.camera.pitch }
                        apply(p.request, animated: true, pitch: ctx.camera.pitch)
                    }
                }
            }
            // Moving the map yourself keeps location fixes from re-framing it.
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in userMovedMap() })
            .simultaneousGesture(MagnifyGesture().onChanged { _ in userMovedMap() })
            .simultaneousGesture(RotateGesture().onChanged { _ in userMovedMap() })
            .simultaneousGesture(TapGesture().onEnded { model.mapTapped() })
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { mapFrame = $0; fitter.viewSize = $0.size }
            .ignoresSafeArea()
        }
        .overlay {
            Color.clear
                .allowsHitTesting(false)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { safeFrame = $0 }
        }
        .overlay(alignment: .topTrailing) {
            MapCompass(scope: mapScope)
                .padding(.trailing, 16)
                .padding(.top, 8)
        }
        .mapScope(mapScope)
    }

    // MARK: Map content

    @MapContentBuilder
    private var mapContent: some MapContent {
        let route = model.engine.routeCoordinates
        if mode == .driver {
            // traffic heat on the streets around each crossing, under the track, strongest at it
            ForEach(heatPieces) { p in
                MapPolyline(coordinates: p.coords)
                    .stroke(p.color.opacity(p.alpha), style: StrokeStyle(lineWidth: 8, lineCap: .butt, lineJoin: .round))
            }
        }

        // a soft glow under the route line
        MapPolyline(coordinates: route)
            .stroke(Color.route.opacity(0.25), style: StrokeStyle(lineWidth: 14, lineCap: .round, lineJoin: .round))
        MapPolyline(coordinates: route)
            .stroke(Color.route, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

        let selectedStation = mode == .rider ? model.riderStation?.id : nil
        // In Horse, a station right on your track point would hide its orange dot.
        let hiddenStation = mode == .horse ? model.trackPoint.flatMap { tp in
            model.engine.data.stations.first {
                CLLocation(latitude: $0.lat, longitude: $0.lon).distance(from: CLLocation(latitude: tp.coordinate.latitude, longitude: tp.coordinate.longitude)) < 60
            }?.id
        } : nil
        let stations = model.engine.data.stations.filter { $0.id != hiddenStation }
        // Station circles are drawn as overlays, which MapKit always puts under annotations, so the
        // trains (annotations, stacked by latitude) are never covered by them. A dot-length line
        // with round caps is a circle that stays the same size on screen.
        ForEach(stations) { st in
            let selected = st.id == selectedStation
            let dot = [CLLocationCoordinate2D(latitude: st.lat, longitude: st.lon),
                       CLLocationCoordinate2D(latitude: st.lat + 1e-7, longitude: st.lon)]
            MapPolyline(coordinates: dot)
                .stroke(Color.route, style: StrokeStyle(lineWidth: selected ? 18 : 14, lineCap: .round))
            MapPolyline(coordinates: dot)
                .stroke(.background, style: StrokeStyle(lineWidth: selected ? 10 : 9, lineCap: .round))
        }
        // An invisible annotation over each circle makes it tappable and gives it its name.
        ForEach(stations) { st in
            Annotation(st.name, coordinate: .init(latitude: st.lat, longitude: st.lon), anchor: .center) {
                StationTarget(selected: st.id == selectedStation)
                    // MapKit doesn't report a tap on the selected station; tapping it again goes back to the nearest one
                    .gesture(TapGesture().onEnded { model.select(nil, onFeature: true) },
                             including: mode == .rider && model.selectedStationId == st.id ? .all : .subviews)
            }
            .tag(MapItem.station(st.id))
        }

        if mode == .driver {
            // The crossings' dots are overlays too, like the stations', so they're always under the
            // annotations and never cover the crossing label (annotations stack by latitude).
            ForEach(model.crossings) { c in
                let dot = [c.coordinate, CLLocationCoordinate2D(latitude: c.coordinate.latitude + 1e-7, longitude: c.coordinate.longitude)]
                MapPolyline(coordinates: dot)
                    .stroke(.background, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                MapPolyline(coordinates: dot)
                    .stroke(c.heatColor ?? .gray, style: StrokeStyle(lineWidth: 10, lineCap: .round))
            }
            let labeled = model.labeledCrossingId
            let delays = pulseDelays
            ForEach(model.crossings) { c in
                Annotation("", coordinate: c.coordinate, anchor: .top) {
                    CrossingDot(state: c, label: c.id == labeled ? model.label(for: c) : nil, pulseDelay: delays[c.id])
                        .gesture(TapGesture().onEnded { model.select(nil, onFeature: true) },
                                 including: model.selectedCrossingId == c.id ? .all : .subviews)
                }
                .annotationTitles(.hidden)
                .tag(MapItem.crossing(c.id))
            }
            // no train on the map yet for your crossing: when it leaves its first station
            if let p = model.driverPendingDeparture {
                Annotation("", coordinate: .init(latitude: p.station.lat, longitude: p.station.lon), anchor: .bottom) {
                    DepartureLabel(text: model.departureText(p.departs))
                        .padding(.bottom, 14) // above the station dot
                }
                .annotationTitles(.hidden)
            }
        }

        if mode == .horse, let tp = model.trackPoint {
            Annotation("Track nearest you", coordinate: tp.coordinate, anchor: .center) {
                Circle()
                    .fill(Color.brandOrange)
                    .stroke(.background, lineWidth: 2.5)
                    .frame(width: 14, height: 14)
            }
            .annotationTitles(.hidden)
        }

        // The live trains are annotations, so MapKit moves them with the map in the same frame.
        let focus = model.focusTripId
        ForEach(model.trains) { t in
            Annotation("", coordinate: t.coordinate, anchor: .center) {
                TrainMark(train: t,
                          camera: cameraAngle,
                          dimmed: focus != nil && t.trip.id != focus,
                          leaving: model.isLeavingRiderStation(t),
                          departure: t.departsAt.map { model.departureText($0) })
            }
            .annotationTitles(.hidden)
        }

        // Drawn by hand: on the tilted map MapKit's puck lies flat as a disc, takes the app's green
        // tint, and has no cone unless the map itself follows the heading.
        let heading = model.location.heading
        UserAnnotation {
            UserLocationDot(heading: heading, camera: cameraAngle)
        }
    }

    /// Each train's yellow and red crossings pulse one after another, in the order that train
    /// reaches (or reached) them, so the wave runs the way the train is going. Each train runs its own wave.
    private var pulseDelays: [String: Double] {
        let hot = model.crossings.filter { $0.heat != nil }
        var delays: [String: Double] = [:]
        for group in Dictionary(grouping: hot, by: { $0.cause?.trip }).values {
            let ordered = group.sorted { ($0.cause?.at ?? 0) < ($1.cause?.at ?? 0) }
            let step = min(0.4, 2.4 / Double(ordered.count))
            for (i, c) in ordered.enumerated() { delays[c.id] = Double(i) * step }
        }
        return delays
    }

    private struct HeatPiece: Identifiable {
        let id: String
        let coords: [CLLocationCoordinate2D]
        let color: Color
        let alpha: Double
    }

    private var heatPieces: [HeatPiece] {
        var out: [HeatPiece] = []
        for c in model.crossings {
            guard let heat = c.heat else { continue }
            let (color, a): (Color, Double) = switch heat {
            case .yellow: (.heatYellow, 1)
            case .red(let a): (.heatRed, a)
            }
            for (i, p) in c.pieces.enumerated() {
                let alpha = 0.85 * a * max(0, 1 - p.mid / TrainEngine.armM)
                if alpha > 0.02 { out.append(HeatPiece(id: "\(c.id)-\(i)", coords: p.coords, color: color, alpha: alpha)) }
            }
        }
        return out
    }

    /// Station or crossing taps. Horse has nothing to tap.
    private var selection: Binding<MapItem?> {
        Binding {
            switch mode {
            case .rider: model.selectedStationId.map { .station($0) }
            case .driver: model.selectedCrossingId.map { .crossing($0) }
            case .horse: nil
            }
        } set: { item in
            switch (mode, item) {
            case (.horse, _): return
            // in Driver, a tap that isn't on a crossing goes back to the one nearest you
            case (.driver, .station?): model.select(nil, onFeature: false)
            default: model.select(item, onFeature: item != nil)
            }
        }
    }

    // MARK: Card and controls

    private var card: some View {
        Group {
            switch mode {
            case .rider: RiderCard()
            case .horse: HorseCard()
            case .driver: DriverCard()
            }
        }
    }

    /// The card, placed by the screen's shape:
    /// - landscape: a panel in the bottom leading corner, beside the map buttons' bar;
    /// - portrait: the same panel along the bottom, centered (full width on narrow screens);
    /// - iPhone Duo folded across its middle: open like a laptop, it's the arrivals board,
    ///   centered in the upright top half at 1.1×; less open, it stays at the bottom, below the fold.
    /// With no bar along the bottom (the bars are on the side), the card's bottom lines up with
    /// the bottom of the side bar.
    private var cardLayer: some View {
        GeometryReader { proxy in
            // This layer ignores the safe area (so the card can line up with a side bar's bottom),
            // which zeroes its own insets; the map's safe area gives the real ones.
            let size = proxy.size, insets = safeAreaInsets
            let fold = horizontalFold(in: proxy)
            let landscape = fold == nil && size.width > size.height
            let safeWidth = size.width - insets.leading - insets.trailing
            let width = landscape ? min(420, safeWidth * 0.6) : min(420, safeWidth - 24)
            let laptop = fold != nil && isLaptopPose
            // A bottom bar (the tab bar in portrait) takes the bottom safe area; side bars leave
            // only the home indicator, and sit this far from the screen's edge.
            let bottomGap = insets.bottom > 44 ? insets.bottom + 8 : Self.sideBarEdgeGap
            // One layout for every state, so the card glides between them rather than being
            // swapped: in laptop pose it's the arrivals board, centered between the top bars and
            // the fold; otherwise it sits at the bottom.
            let above = laptop ? insets.top : (fold.map { $0.maxY } ?? insets.top)
            let below = laptop ? size.height - (fold?.minY ?? 0) : bottomGap
            VStack(alignment: landscape ? .leading : .center, spacing: 0) {
                Color.clear.frame(height: above)
                // Framed like the spacer below, so the two share the free height equally in laptop pose.
                Spacer(minLength: 8)
                    .frame(maxHeight: .infinity)
                card
                    .frame(width: max(0, width))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { cardFrame = $0 }
                    .scaleEffect(laptop ? 1.1 : 1)
                    // The card is offered all the free height before the spacers split what's left;
                    // otherwise it gets an equal share with them and scrolls when it would fit.
                    .layoutPriority(1)
                // Centers the board in laptop pose; collapses otherwise.
                Spacer(minLength: laptop ? 8 : 0)
                    .frame(maxHeight: laptop ? .infinity : 0)
                Color.clear.frame(height: below)
            }
            .animation(reduceMotion ? nil : .smooth(duration: 0.45), value: laptop)
            // Centered or leading within the safe area, so it never runs under a side bar.
            .frame(maxWidth: .infinity, alignment: landscape ? .leading : .center)
            .padding(.leading, insets.leading + (landscape ? 12 : 0))
            .padding(.trailing, insets.trailing)
            .onChange(of: fold.map { $0.offsetBy(dx: proxy.frame(in: .global).minX, dy: proxy.frame(in: .global).minY) }, initial: true) { _, f in
                foldFrame = f
            }
        }
        .ignoresSafeArea()
    }

    /// The bars' insets around the map, from its full-screen and safe-area frames.
    private var safeAreaInsets: EdgeInsets {
        guard mapFrame != .zero, safeFrame != .zero else { return EdgeInsets() }
        return EdgeInsets(top: safeFrame.minY - mapFrame.minY, leading: safeFrame.minX - mapFrame.minX,
                          bottom: mapFrame.maxY - safeFrame.maxY, trailing: mapFrame.maxX - safeFrame.maxX)
    }

    /// Where the side bars sit from the screen's bottom edge on iPhone Duo.
    private static let sideBarEdgeGap: CGFloat = 24

    /// The active fold, when it runs across the screen (the inner display held like a laptop),
    /// in the proxy's coordinates. A fold down the middle of a landscape screen is ignored: the
    /// map and card work as they do when it's flat.
    private func horizontalFold(in proxy: GeometryProxy) -> CGRect? {
        guard #available(iOS 27.1, *) else { return nil }
        return proxy.reservedRegions(kind: .division)
            .first { $0.isActive && $0.frame.width > $0.frame.height }?
            .frame
    }

    /// Show my location; the symbol says when location is off or still being found.
    private var locateButton: some View {
        Button {
            if model.location.status == .denied { showLocationHelp = true } else { model.locate() }
        } label: {
            Label("Show My Location", systemImage: locateSymbol)
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.pulse, isActive: model.location.status == .locating && !reduceMotion)
                .animation(.default, value: locateSymbol)
        }
    }

    private var locateSymbol: String {
        switch model.location.status {
        case .denied, .unavailable: "location.slash"
        case .locating: "location"
        default: "location.fill"
        }
    }

    // MARK: Camera

    /// How far in from each edge of the map the framed points must stay: inside the safe area
    /// (the bars, wherever the system put them) and clear of the card where it covers the map,
    /// with extra room so markers (and Driver's crossing label) aren't cut off.
    private func clearArea(for f: FramingRequest) -> EdgeInsets {
        let margin: CGFloat = f.overview ? 30 : 56
        let labelRoom: CGFloat = mode == .driver ? 28 : 0
        // Labels ("Departs in 19 min", "Train in 4 min") are centered on their point, so they reach
        // about this far to either side of it.
        let sideMargin = max(margin, 80)
        var insets = EdgeInsets(top: safeFrame.minY - mapFrame.minY + 24,
                                leading: safeFrame.minX - mapFrame.minX + sideMargin,
                                bottom: mapFrame.maxY - safeFrame.maxY + 24 + labelRoom,
                                trailing: mapFrame.maxX - safeFrame.maxX + sideMargin)
        // Folded, the map's subject stays on the map's side of the fold: the flat bottom half in
        // laptop pose, the top half otherwise.
        if let fold = foldFrame {
            if isLaptopPose {
                // The flat bottom half is the map; the map only runs on into the upright half, behind
                // the arrivals board, for looks. Frame in the bottom half alone, ignoring the card.
                insets.top = max(insets.top, fold.maxY - mapFrame.minY + 24)
                return insets
            } else {
                insets.bottom = max(insets.bottom, mapFrame.maxY - fold.minY + 24 + labelRoom)
            }
        }
        let covered = cardFrame.intersection(mapFrame)
        if !covered.isNull, covered.width > 0 {
            if covered.width > mapFrame.width * 0.6 {
                insets.bottom = max(insets.bottom, mapFrame.maxY - covered.minY + 28 + labelRoom)
            } else if covered.midX < mapFrame.midX {
                insets.leading = max(insets.leading, covered.maxX - mapFrame.minX + 32)
            } else {
                insets.trailing = max(insets.trailing, mapFrame.maxX - covered.minX + 32)
            }
        }
        return insets
    }

    /// Your own move wins: drop any pending re-fit, so the camera doesn't pull away from it.
    /// Called on every gesture update, so it only writes state when there's something to clear:
    /// rebuilding the map mid-gesture re-applies the camera and cancels the pan.
    private func userMovedMap() {
        if pendingFraming != nil { pendingFraming = nil }
        model.userMovedMap()
    }

    private func apply(_ f: FramingRequest, animated: Bool, pitch refitPitch: Double? = nil, force: Bool = false) {
        if refitPitch == nil && !force {
            guard f.id != appliedFramingId else { return }
            appliedFramingId = f.id
        }
        lastFraming = f
        var fit = fitter
        fit.viewSize = mapFrame.size == .zero ? fit.viewSize : mapFrame.size
        if mapFrame != .zero { fit.insets = clearArea(for: f) }
        // North-up at the default tilt (the whole line asks for what MapKit allowed last time,
        // so it doesn't have to re-fit).
        let wantPitch = refitPitch ?? (f.overview ? allowedPitch : CameraFitter.pitch)
        guard let camera = fit.camera(fitting: f.points, maxZoom: f.maxZoom, pitch: wantPitch) else { return }
        pendingFraming = refitPitch == nil ? (f, camera.pitch) : nil
        if animated {
            withAnimation(.easeInOut(duration: refitPitch != nil ? 0.6 : 1.6)) { position = .camera(camera) }
        } else {
            position = .camera(camera)
        }
    }
}

/// Tracks iPhone Duo's hinge: open like a laptop (70° or more) or less open, as when held.
private struct HingeReader: ViewModifier {
    @Binding var isLaptopPose: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange { _, context in
                guard let hinge = context.hinge else { return isLaptopPose = false }
                // 0° is closed, 180° flat.
                isLaptopPose = hinge.status == .partiallyOpen && hinge.angle.degrees >= 70
            }
        } else {
            content
        }
    }
}

/// What the camera's clear area depends on; a change re-frames the map.
private struct LayoutKey: Equatable {
    let map: CGRect, safe: CGRect, card: CGRect, fold: CGRect?, laptop: Bool
}

// MARK: - Map marks

private extension Color {
    static let heatYellow = Color(red: 0xf2 / 255, green: 0xb6 / 255, blue: 0x00 / 255)
    static let heatRed = Color(red: 0xe0 / 255, green: 0x35 / 255, blue: 0x2b / 255)
}

/// The camera's rotation and tilt. Only written when they change (a pan changes neither),
/// so panning doesn't re-render the arrows.
@Observable
private final class CameraAngle {
    private(set) var heading = 0.0
    private(set) var pitch = 0.0

    func update(_ camera: MapCamera) {
        if heading != camera.heading { heading = camera.heading }
        if pitch != camera.pitch { pitch = camera.pitch }
    }
}

/// Where you are, as the iOS blue dot, with a cone showing which way the phone faces.
private struct UserLocationDot: View {
    let heading: LocationProvider.Heading?
    let camera: CameraAngle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The compass direction, unwrapped (359° to 1° turns 2°, not back 358°) so it animates the short way.
    @State private var turn = 0.0

    var body: some View {
        ZStack {
            HeadingCone(spread: spread)
                .fill(RadialGradient(colors: [.blue.opacity(0.55), .blue.opacity(0)],
                                     center: .center, startRadius: 6, endRadius: 46))
                .frame(width: 92, height: 92)
                // Smooth out compass jitter; the map's own rotation below follows it exactly.
                .rotationEffect(.degrees(turn))
                .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: turn)
                .rotationEffect(.degrees(-camera.heading))
                // Lies on the ground, so tilting the map flattens it like the streets.
                .scaleEffect(x: 1, y: cos(camera.pitch * .pi / 180))
                .opacity(heading == nil ? 0 : 1)
                .animation(.easeInOut(duration: 0.3), value: heading == nil)
                .animation(.easeInOut(duration: 0.3), value: spread)
                .accessibilityHidden(true)

            Circle()
                .fill(.blue)
                .padding(4)
                .background(.white, in: .circle)
                .frame(width: 22, height: 22)
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your location")
        .onChange(of: heading?.degrees, initial: true) { _, degrees in
            guard let degrees else { return }
            // Step by the shortest way round from where the cone points now.
            turn += (degrees - turn).remainder(dividingBy: 360)
        }
    }

    /// Wider when the compass is less sure, like the system's cone.
    private var spread: Double {
        min(max((heading?.accuracy ?? 30) * 2, 40), 100)
    }
}

/// A wedge pointing up from the center, `spread` degrees wide.
private struct HeadingCone: Shape {
    var spread: Double

    var animatableData: Double {
        get { spread }
        set { spread = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: center)
        path.addArc(center: center, radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(-90 - spread / 2), endAngle: .degrees(-90 + spread / 2), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// One live train on the map, pointing the way it's going on screen.
private struct TrainMark: View {
    let train: TrainPosition
    let camera: CameraAngle
    let dimmed: Bool
    let leaving: Bool
    /// Set while the train waits at its first station: when it leaves.
    let departure: String?

    var body: some View {
        TrainPointer(dimmed: dimmed, leaving: leaving)
            .rotationEffect(.degrees(screenAngle))
            .accessibilityLabel(train.trip.dir == 1 ? "Northbound train to \(train.trip.headsign)" : "Southbound train to \(train.trip.headsign)")
            // An overlay, so the annotation stays centered on the arrow.
            .overlay {
                if let departure {
                    DepartureLabel(text: departure)
                        .offset(y: -34) // above, clear of the station name
                }
            }
            .allowsHitTesting(false)
    }

    /// The way the track bearing points on screen, with the map's rotation and tilt
    /// (tilt shortens the north-south part of the direction).
    private var screenAngle: Double {
        let r = (train.bearing - camera.heading) * .pi / 180
        return atan2(sin(r), cos(r) * cos(camera.pitch * .pi / 180)) * 180 / .pi
    }
}

/// A navigation arrow pointing the way the train is going, outlined so it stands off the route line.
private struct TrainPointer: View {
    let dimmed: Bool
    /// Rider: heading away from your station, so drawn gray and half see-through.
    let leaving: Bool

    var body: some View {
        ArrowShape()
            .fill(leaving ? Color.gray : Color.trainPointer)
            .stroke(.background, style: StrokeStyle(lineWidth: 3.5, lineJoin: .round))
            .frame(width: 26, height: 30)
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
            .opacity(dimmed ? 0.25 : leaving ? 0.5 : 1)
            .animation(.easeInOut(duration: 0.2), value: dimmed)
            .animation(.easeInOut(duration: 0.2), value: leaving)
    }
}

/// When a train leaves its first station, in a glass capsule like the crossing label.
private struct DepartureLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassBackground(in: .capsule)
            .fixedSize()
    }
}

private struct ArrowShape: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.midX, y: r.minY + r.height * 0.77))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

/// The tap target for a station; its circle is drawn under it as a map overlay.
private struct StationTarget: View {
    let selected: Bool

    var body: some View {
        Color.clear
            // the circle's size, so the station's name sits just under it
            .frame(width: selected ? 18 : 14, height: selected ? 18 : 14)
            .contentShape(.circle)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension CrossingState {
    /// Red or yellow when a train will block the crossing soon.
    var heatColor: Color? {
        switch heat {
        case .yellow: .heatYellow
        case .red: .heatRed
        case nil: nil
        }
    }
}

/// What sits on each crossing's dot (the dot itself is a map overlay): its tap target, a soft
/// pulse when a train will block it soon, and the next traffic event under the crossing nearest you.
private struct CrossingDot: View {
    let state: CrossingState
    let label: (title: String, subtitle: String?)?
    /// Seconds into the shared pulse wave when this crossing rings (nil = not hot).
    let pulseDelay: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let color = state.heatColor, let pulseDelay, !reduceMotion {
                    PulseRing(color: color, delay: pulseDelay)
                }
                // the dot's tap target
                Color.clear
                    .frame(width: 14, height: 14)
                    .contentShape(.circle)
            }
            .frame(width: 14, height: 14)
            if let label {
                VStack(spacing: 0) {
                    Text(label.title).font(.footnote.bold())
                        .contentTransition(.numericText(countsDown: true))
                    if let sub = label.subtitle { Text(sub).font(.caption2).foregroundStyle(.secondary) }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassBackground(in: .capsule)
                .fixedSize()
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85, anchor: .top)))
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.3), value: label?.title)
        // anchor the dot, not the label, on the crossing
        .offset(y: -7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label.map { [$0.title, $0.subtitle].compactMap { $0 }.joined(separator: ", ") } ?? String(localized: "Level crossing"))
    }
}

/// One soft ring per 5 s wave, easing out as it grows and fading to nothing.
private struct PulseRing: View {
    static let cycle = 5.0, ringDuration = 1.8
    let color: Color
    let delay: Double

    static let maxRadius = 45.0
    /// Wave boundaries aligned to the epoch, so every crossing's ring shares the same clock.
    private static let waveStart = Date(timeIntervalSince1970: 0)

    var body: some View {
        // Ticks once per wave rather than every frame; the keyframe animation then plays the ring.
        // Only scale and opacity change per frame (no layout), and nothing runs between rings.
        TimelineView(.periodic(from: Self.waveStart, by: Self.cycle)) { context in
            Color.clear
                .keyframeAnimator(initialValue: 1.0, trigger: context.date) { content, r in
                    let p = max(0, min(1, r))
                    let fade = r < 0 || r >= 1 ? 0 : pow(1 - p, 2)
                    let scale = (5 + 40 * (1 - pow(1 - p, 3))) / Self.maxRadius
                    Circle()
                        .fill(color.opacity(0.25))
                        // counter the scale so the stroke stays 1.5 pt on screen
                        .stroke(color.opacity(0.8), lineWidth: 1.5 / scale)
                        .frame(width: Self.maxRadius * 2, height: Self.maxRadius * 2)
                        .scaleEffect(scale)
                        .opacity(fade)
                } keyframes: { _ in
                    // -1 = waiting for this crossing's turn in the wave (hidden), 0…1 = ring progress
                    MoveKeyframe(-1)
                    LinearKeyframe(-1, duration: delay)
                    MoveKeyframe(0)
                    LinearKeyframe(1, duration: Self.ringDuration)
                }
        }
        .frame(width: 14, height: 14)
        .allowsHitTesting(false)
    }
}
