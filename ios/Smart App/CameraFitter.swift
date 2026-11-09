import SwiftUI
import MapKit

/// Fits points into the clear part of the screen in the tilted view itself, the way the web
/// prototype did: try a camera, work out where the points land on screen, adjust, repeat.
///
/// Screen positions come from a simple perspective model of MapKit's camera. Its focal length
/// and where the camera's center lands on screen are calibrated from the live map whenever the
/// camera settles (see `calibrate`), so the model matches what MapKit actually draws.
struct CameraFitter {
    /// The tilt we ask for. MapKit allows less when zoomed out, so a fit can be re-run with the
    /// pitch it actually used (see MapScreen).
    static let pitch = 45.0

    var viewSize = CGSize(width: 390, height: 844)
    /// The part of the view that must contain the points (clear of the card and buttons).
    var insets = EdgeInsets(top: 70, leading: 40, bottom: 300, trailing: 40)
    /// Focal length in points. Until calibrated, assume a 30° vertical field of view.
    var focal: Double?
    /// Where the camera's center coordinate lands, relative to the view's center.
    var centerOffset = CGPoint.zero

    private var f: Double { focal ?? Double(viewSize.height) / 2 / tan(15 * Double.pi / 180) }

    /// Learns the focal length from where MapKit draws a point 200 m to the camera's right.
    /// That point is as far from the eye as the center is, so its offset on screen is 200 × f / distance.
    mutating func calibrate(camera: MapCamera, proxy: MapProxy) {
        let c = camera.centerCoordinate
        let b = (camera.heading + 90) * .pi / 180
        let side = CLLocationCoordinate2D(latitude: c.latitude + 200 * cos(b) / 110_540,
                                          longitude: c.longitude + 200 * sin(b) / (111_320 * cos(c.latitude * .pi / 180)))
        guard let p0 = proxy.convert(c, to: .local), let p1 = proxy.convert(side, to: .local) else { return }
        let px = hypot(p1.x - p0.x, p1.y - p0.y)
        guard px > 1 else { return }
        focal = Double(px) * camera.distance / 200
        centerOffset = CGPoint(x: p0.x - viewSize.width / 2, y: p0.y - viewSize.height / 2)
    }

    /// Camera distance at which the map shows a web-map zoom level (512-point tiles) at this latitude.
    func distance(forZoom z: Double, latitude: Double) -> Double {
        78_271.517 * cos(latitude * .pi / 180) / pow(2, z) * f
    }

    func camera(fitting points: [CLLocationCoordinate2D], maxZoom: Double?, pitch: Double = Self.pitch, heading: Double = 0) -> MapCamera? {
        guard !points.isEmpty else { return nil }
        let lat0 = points.map(\.latitude).reduce(0, +) / Double(points.count)
        let lon0 = points.map(\.longitude).reduce(0, +) / Double(points.count)
        let kx = 111_320 * cos(lat0 * .pi / 180), ky = 110_540.0
        // points in meters east and north of their centroid, turned so +y is the way the camera faces
        let hr = heading * .pi / 180
        let local = points.map { p -> (x: Double, y: Double) in
            let e = (p.longitude - lon0) * kx, n = (p.latitude - lat0) * ky
            return (e * cos(hr) - n * sin(hr), e * sin(hr) + n * cos(hr))
        }
        let theta = pitch * .pi / 180
        let minD = maxZoom.map { distance(forZoom: $0, latitude: lat0) } ?? 300
        let maxD = 600_000.0
        let clampD = { (d: Double) in min(maxD, max(minD, d)) }

        let box = (l: Double(insets.leading), r: Double(viewSize.width - insets.trailing),
                   t: Double(insets.top), b: Double(viewSize.height - insets.bottom))
        guard box.r - box.l > 20, box.b - box.t > 20 else { return nil }
        let sc = (x: Double(viewSize.width / 2 + centerOffset.x), y: Double(viewSize.height / 2 + centerOffset.y))

        func project(_ p: (x: Double, y: Double), _ cx: Double, _ cy: Double, _ d: Double) -> (x: Double, y: Double)? {
            let dx = p.x - cx, dy = p.y - cy
            let depth = dy * sin(theta) + d
            guard depth > 1 else { return nil }
            return (sc.x + dx * f / depth, sc.y - dy * cos(theta) * f / depth)
        }
        func extent(_ cx: Double, _ cy: Double, _ d: Double) -> (x0: Double, x1: Double, y0: Double, y1: Double)? {
            var e = (x0: Double.infinity, x1: -Double.infinity, y0: Double.infinity, y1: -Double.infinity)
            for p in local {
                guard let s = project(p, cx, cy, d) else { return nil }
                e = (min(e.x0, s.x), max(e.x1, s.x), min(e.y0, s.y), max(e.y1, s.y))
            }
            return e
        }

        var cx = (local.map(\.x).min()! + local.map(\.x).max()!) / 2
        var cy = (local.map(\.y).min()! + local.map(\.y).max()!) / 2
        // Start from the flat fit, then refine in the tilted view.
        let w = local.map(\.x).max()! - local.map(\.x).min()!, h = local.map(\.y).max()! - local.map(\.y).min()!
        var d = clampD(max(w / (box.r - box.l), h * cos(theta) / (box.b - box.t)) * f * 1.2)

        if points.count > 1 {
            for _ in 0..<10 {
                guard let e = extent(cx, cy, d) else { d = clampD(d * 1.5); continue }
                let s = min((box.r - box.l) / max(1, e.x1 - e.x0), (box.b - box.t) / max(1, e.y1 - e.y0))
                let dsx = (e.x0 + e.x1) / 2 - (box.l + box.r) / 2
                let dsy = (e.y0 + e.y1) / 2 - (box.t + box.b) / 2
                cx += dsx * d / f
                cy -= dsy * d / (f * cos(theta))
                d = clampD(d / pow(s, 0.8))
            }
        } else {
            cx = local[0].x; cy = local[0].y
            d = minD
        }
        // make sure: back out until everything is inside, re-centering as we go
        for _ in 0..<30 {
            guard let e = extent(cx, cy, d) else { d = clampD(d * 1.1); continue }
            if e.x0 >= box.l - 1 && e.x1 <= box.r + 1 && e.y0 >= box.t - 1 && e.y1 <= box.b + 1 { break }
            if d >= maxD { break }
            cx += ((e.x0 + e.x1) / 2 - (box.l + box.r) / 2) * d / f
            cy -= ((e.y0 + e.y1) / 2 - (box.t + box.b) / 2) * d / (f * cos(theta))
            d = clampD(d * 1.07)
        }
        // turn the solved center back to east/north
        let e = cx * cos(hr) + cy * sin(hr), n = -cx * sin(hr) + cy * cos(hr)
        let center = CLLocationCoordinate2D(latitude: lat0 + n / ky, longitude: lon0 + e / kx)
        return MapCamera(centerCoordinate: center, distance: d, heading: heading, pitch: pitch)
    }
}
