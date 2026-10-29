// Debug builds only: a short log of what the monitor saw and decided, plus a snapshot of what iOS is monitoring.
// Kept in the App Group so it can be copied off a test iPhone:
//   xcrun devicectl device copy from --device <udid> --domain-type appGroupDataContainer \
//     --domain-identifier group.io.github.weldingarc.arclock --source Library/Preferences --destination <dir>
// Release builds compile these to nothing.
import DeviceActivity
import Foundation

enum Diag {
    #if DEBUG
    private static let logKey = "diag.log"
    private static let dumpKey = "diag.monitors"

    static func log(_ line: @autoclosure () -> String) {
        // nothing is written to the shared data while it can't be read (before the first unlock after a restart): a
        // write then could replace what's saved
        guard StateStore.isSaved else { return }
        var lines = AppGroup.defaults.stringArray(forKey: logKey) ?? []
        lines.append("\(stamp(Date())) \(line())")
        if lines.count > 400 { lines.removeFirst(lines.count - 400) }
        AppGroup.defaults.set(lines, forKey: logKey)
    }

    /// The monitors iOS holds for Arc Lock right now: schedule, next interval and event thresholds.
    static func dumpMonitors() {
        guard StateStore.isSaved else { return }          // see `log`
        let center = DeviceActivityCenter()
        var out: [String] = ["at \(stamp(Date()))"]
        for name in center.activities.sorted(by: { $0.rawValue < $1.rawValue }) {
            var line = name.rawValue
            if let s = center.schedule(for: name) {
                line += " | \(comps(s.intervalStart))–\(comps(s.intervalEnd)) repeats=\(s.repeats)"
                line += " warn=\(s.warningTime.map(comps) ?? "-")"
                if let i = s.nextInterval { line += " next=\(stamp(i.start))→\(stamp(i.end))" }
            }
            for (event, e) in center.events(for: name).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                line += " | \(event.rawValue)=\(comps(e.threshold)) apps=\(e.applications.count) cats=\(e.categories.count)"
                line += " webs=\(e.webDomains.count) past=\(e.includesPastActivity)"
            }
            out.append(line)
        }
        AppGroup.defaults.set(out, forKey: dumpKey)
    }

    /// Test monitors on the first time-out's apps, 2 minutes each: event named "limit" (like every rule) or unique,
    /// with or without a 1-minute warning. Started with `-probe start` at launch, removed with `-probe stop`.
    static let probeNames = ["probe.A", "probe.B", "probe.C", "probe.D"].map { DeviceActivityName($0) }
    static func startProbes(_ state: ArcState) {
        guard let sel = state.rules.first(where: { $0.plan.kind == .timeout })?.selection else { log("probe: no time-out"); return }
        let center = DeviceActivityCenter()
        func schedule(warn: Bool) -> DeviceActivitySchedule {
            DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0), intervalEnd: DateComponents(hour: 23, minute: 59),
                                   repeats: true, warningTime: warn ? DateComponents(minute: 1) : nil)
        }
        let event = DeviceActivityEvent(applications: sel.applicationTokens, categories: sel.categoryTokens,
                                        webDomains: sel.webDomainTokens, threshold: DateComponents(minute: 2), includesPastActivity: false)
        let probes: [(DeviceActivityName, Bool, String)] = [(probeNames[0], true, "limit"), (probeNames[1], false, "limit"),
                                                            (probeNames[2], true, "probeC.limit"), (probeNames[3], false, "probeD.limit")]
        for (name, warn, e) in probes {
            do {
                try center.startMonitoring(name, during: schedule(warn: warn), events: [DeviceActivityEvent.Name(e): event])
                log("probe \(name.rawValue) registered: event \(e), warning \(warn)")
            } catch { log("probe \(name.rawValue) FAILED: \(error)") }
        }
    }
    static func stopProbes() {
        DeviceActivityCenter().stopMonitoring(probeNames)
        log("probes removed")
    }

    private static func comps(_ c: DateComponents) -> String {
        [c.hour.map { "\($0)h" }, c.minute.map { "\($0)m" }, c.second.map { "\($0)s" }].compactMap { $0 }.joined()
    }
    private static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f.string(from: d)
    }
    #else
    static func log(_ line: @autoclosure () -> String) {}
    static func dumpMonitors() {}
    static let probeNames: [DeviceActivityName] = []
    #endif
}
