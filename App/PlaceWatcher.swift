// Place blocks: iOS watches the circle around each chosen place and tells Arc Lock when you cross its edge — even
// while the app is closed (it's relaunched in the background for a few seconds). Arc Lock then starts or ends the
// block. Location access is asked for only when the user sets up a place block, and Arc Lock never sends the location
// anywhere: nothing here is stored except whether you're inside each place.
import CoreLocation
import Foundation
import UIKit

extension Notification.Name {
    /// A place block started or ended (the app redraws if it's open).
    static let placesChanged = Notification.Name("placesChanged")
}

final class PlaceWatcher: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = PlaceWatcher()

    enum Access: Equatable {
        /// Not asked yet (asked only when a place block is set up).
        case notAsked
        /// Only while Arc Lock is open: a place block can't start or end while it's closed.
        case whileUsing
        /// What place blocks need.
        case always
        /// Approximate location: iOS can't tell when you arrive or leave.
        case approximate
        case denied
    }

    @Published private(set) var access: Access = .notAsked
    /// The latest location iOS reported (for "you're there now" and centering the map). Kept in memory only.
    @Published private(set) var location: CLLocation?

    private let manager = CLLocationManager()
    /// Set while the first request (while using) is showing, so the second (always) follows right after.
    private var upgradeNext = false
    private static let askedAlwaysKey = "placesAskedAlways"
    /// iOS shows its "Always" question only once; after that the choice is made in Settings.
    var askedAlways: Bool { UserDefaults.standard.bool(forKey: Self.askedAlwaysKey) }

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        readAccess()
        // after a restart, crossings that came before the first unlock were ignored (the state couldn't be read):
        // ask again where you are once it can
        NotificationCenter.default.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.sync(StateStore.load())
            self?.recheck()
        }
    }

    /// Whether a loaded state is real. Before the first unlock after a restart iOS can't read the shared state and it
    /// looks empty (never set up); a real one is always onboarded, since place blocks exist only after setup. (Being
    /// locked doesn't matter: once unlocked after a restart, the state stays readable while the iPhone is locked.)
    private func readable(_ state: ArcState) -> Bool { state.onboarded }

    /// Called at launch — also when iOS relaunches the app in the background for a crossing, which it delivers to
    /// this delegate.
    func start() {
        readAccess()
    }

    private func readAccess() {
        let precise = manager.accuracyAuthorization == .fullAccuracy
        switch manager.authorizationStatus {
        case .notDetermined: access = .notAsked
        case .authorizedWhenInUse: access = precise ? .whileUsing : .approximate
        case .authorizedAlways: access = precise ? .always : .approximate
        case .denied, .restricted: access = .denied
        @unknown default: access = .denied
        }
    }

    /// Shows iOS's own location questions: first "while using the app", then "always" (place blocks need both).
    func requestAccess() {
        switch manager.authorizationStatus {
        case .notDetermined:
            upgradeNext = true
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse:
            UserDefaults.standard.set(true, forKey: Self.askedAlwaysKey)
            manager.requestAlwaysAuthorization()
        default:
            break
        }
    }

    /// The current location, once (for the map and the "you're there now" note). Needs access.
    func locate() {
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else { return }
        manager.requestLocation()
    }

    /// Watches every place of every switched-on place block, and nothing else. iOS watches at most 20 places for an
    /// app (the app refuses more); each is named "<block id>#<position>".
    func sync(_ state: ArcState) {
        guard readable(state) else { return }
        let blocks = state.rules.filter { $0.plan.kind == .place && $0.plan.isOn }
        var wanted: [String: CLCircularRegion] = [:]
        for rule in blocks {
            for (i, spot) in rule.plan.places.enumerated() where wanted.count < Limits.maxPlaces {
                let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude),
                                              radius: min(spot.radius, manager.maximumRegionMonitoringDistance),
                                              identifier: "\(rule.id.uuidString)#\(i)")
                region.notifyOnEntry = true
                region.notifyOnExit = true
                wanted[region.identifier] = region
            }
        }
        for region in manager.monitoredRegions {
            guard let want = wanted[region.identifier], let have = region as? CLCircularRegion,
                  have.center.latitude == want.center.latitude, have.center.longitude == want.center.longitude,
                  have.radius == want.radius else {
                manager.stopMonitoring(for: region)
                continue
            }
            wanted[region.identifier] = nil          // already watched as it should be
        }
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else { return }
        for region in wanted.values { manager.startMonitoring(for: region) }
    }

    /// Asks iOS where you are for every watched place (when the app opens: catches a crossing it didn't report), or
    /// for one block's places (after its places, days or ending changed).
    func recheck(_ id: UUID? = nil) {
        for region in manager.monitoredRegions where id == nil || region.identifier.hasPrefix(id!.uuidString) {
            manager.requestState(for: region)
        }
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        readAccess()
        if manager.authorizationStatus == .authorizedWhenInUse, upgradeNext {
            upgradeNext = false
            UserDefaults.standard.set(true, forKey: Self.askedAlwaysKey)
            manager.requestAlwaysAuthorization()
        } else if manager.authorizationStatus != .notDetermined {
            upgradeNext = false
        }
        sync(StateStore.load())
    }

    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        // a new place: if you're already there, the block starts now
        manager.requestState(for: region)
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        switch state {
        case .inside: crossed(region.identifier, inside: true)
        case .outside: crossed(region.identifier, inside: false)
        case .unknown: break
        @unknown default: break
        }
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        crossed(region.identifier, inside: true, entered: true)
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        crossed(region.identifier, inside: false)
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        Diag.log("place monitoring failed for \(region?.identifier.prefix(8) ?? "?"): \(error)")
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Diag.log("location failed: \(error)")
    }

    // MARK: arriving and leaving

    /// iOS says you're inside (or outside) one of a block's places: start or end the block, and its shield, right now.
    private func crossed(_ identifier: String, inside: Bool, entered: Bool = false) {
        let parts = identifier.split(separator: "#")
        guard let first = parts.first, let id = UUID(uuidString: String(first)) else { return }
        let spot = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let task = UIApplication.shared.beginBackgroundTask(withName: "place") {}
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        let now = Date()
        let state = StateStore.load()
        guard readable(state) else { return }        // asked again once the iPhone is unlocked (recheck)
        guard let rule = state.rules.first(where: { $0.id == id }), rule.plan.kind == .place, rule.plan.isOn,
              rule.plan.places.indices.contains(spot) else {
            // a place of a deleted or switched-off block
            for region in manager.monitoredRegions where region.identifier == identifier { manager.stopMonitoring(for: region) }
            return
        }
        let before = PlaceVisits.get(id)
        let after = PlaceRules.update(before, plan: rule.plan, spot: spot, inside: inside, entered: entered, now: now,
                                      calendar: .autoupdatingCurrent)
        guard after != before else { return }
        PlaceVisits.set(id, after)
        let wasRunning = PlaceRules.isRunning(before, now: now), running = PlaceRules.isRunning(after, now: now)
        Diag.log("place \(identifier.prefix(8)) \(inside ? "inside" : "outside"): \(wasRunning ? "running" : "idle") → \(running ? "running" : "idle")")
        if running, let started = after.started, !wasRunning || before?.started != after.started || before?.ends != after.ends {
            // a one-off monitor lifts it at its set time — or, when it ends on leaving, at the 12-hour safety end —
            // even if Arc Lock stays closed (restarted when a missed exit made this a new visit)
            if let latest = PlaceRules.latestEnd(after, now: now) { Monitoring.startPlaceEnd(id, from: started, to: latest) }
            if !wasRunning {
                Notify.post(id: "place.\(id)", title: rule.plan.displayName,
                            body: after.ends.map { L("Blocked until %@.", Fmt.time($0)) } ?? L("Blocked until you leave."))
            }
        } else if wasRunning && !running {
            Monitoring.stopPlaceEnd(id)
        }
        let (fresh, _) = Engine.housekeep(now: now)
        Engine.reconcile(fresh, now: now)
        NotificationCenter.default.post(name: .placesChanged, object: nil)
    }
}
