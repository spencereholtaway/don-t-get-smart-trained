import CoreLocation
import Observation

/// Streams the person's location while the app is in use.
@Observable
final class LocationProvider {
    enum Status: Equatable { case idle, locating, ok, denied, unavailable }

    /// Which way the top of the phone points, in degrees clockwise from north, and how far off
    /// that may be (also in degrees).
    struct Heading: Equatable {
        var degrees: Double
        var accuracy: Double
    }

    private(set) var location: CLLocation?
    private(set) var status: Status = .idle
    /// Nil without a compass, or while it needs calibrating.
    private(set) var heading: Heading?
    /// Called for every new fix.
    @ObservationIgnored var onFix: ((CLLocation) -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    #if !os(macOS)
    @ObservationIgnored private var session: CLServiceSession?
    @ObservationIgnored private var compass: Compass?
    #endif

    func start() {
        guard task == nil else { return }
        status = location == nil ? .locating : .ok
        #if os(macOS)
        CLLocationManager().requestWhenInUseAuthorization()
        #else
        session = CLServiceSession(authorization: .whenInUse)
        if CLLocationManager.headingAvailable() {
            compass = Compass { [weak self] in self?.heading = $0 }
        }
        #endif
        task = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard let self else { return }
                    if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted {
                        status = .denied
                    } else if let loc = update.location {
                        location = loc
                        status = .ok
                        onFix?(loc)
                    } else if update.locationUnavailable {
                        status = location == nil ? .unavailable : .ok
                    }
                }
            } catch {
                self?.status = .unavailable
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        #if !os(macOS)
        session?.invalidate()
        session = nil
        compass?.stop()
        compass = nil
        heading = nil
        #endif
    }
}

#if !os(macOS)
/// Reads the compass, which still only reports through a location manager delegate.
private final class Compass: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let onUpdate: (LocationProvider.Heading?) -> Void

    init(onUpdate: @escaping (LocationProvider.Heading?) -> Void) {
        self.onUpdate = onUpdate
        super.init()
        manager.delegate = self
        manager.headingFilter = 1
        manager.startUpdatingHeading()
    }

    func stop() {
        manager.stopUpdatingHeading()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // A negative accuracy means the reading can't be trusted (the compass needs calibrating).
        guard newHeading.headingAccuracy >= 0 else { onUpdate(nil); return }
        // True north needs a location fix; until then, magnetic north is close enough.
        let degrees = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        onUpdate(.init(degrees: degrees, accuracy: newHeading.headingAccuracy))
    }
}
#endif
