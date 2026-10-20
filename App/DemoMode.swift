// Debug builds only: sample blocks for screenshots and UI checks in the simulator, without touching Screen Time.
//   xcrun simctl launch booted io.github.weldingarc.arclock -demo YES -shot home|editor|limit|timeout|timeouts|blocknow|settings|lockin|guide|onboarding
#if DEBUG
import FamilyControls
import Foundation

enum Demo {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "demo") }
    static var shot: String? { UserDefaults.standard.string(forKey: "shot") }

    /// A Monday at 10:30 in the device's time zone, so the sample blocks show every state.
    static var now: Date {
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day], from: Date())
        c.hour = 10; c.minute = 30
        var d = cal.date(from: c)!
        while cal.component(.weekday, from: d) != 2 { d = cal.date(byAdding: .day, value: 1, to: d)! }
        return d
    }

    static let study = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let sleep = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    static let social = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    static let games = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    static let shorts = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!

    static func state() -> ArcState {
        var s = ArcState()
        s.onboarded = !(shot ?? "").hasPrefix("onboarding")
        s.rules = [
            Rule(id: study, plan: RulePlan(name: "Study", kind: .schedule, start: TimeOfDay(9, 0), end: TimeOfDay(17, 0),
                                           days: [2, 3, 4, 5, 6], domains: ["youtube.com", "instagram.com", "reddit.com"]),
                 selection: FamilyActivitySelection()),
            Rule(id: sleep, plan: RulePlan(name: "Sleep", kind: .schedule, start: TimeOfDay(23, 0), end: TimeOfDay(7, 0),
                                           days: Set(1...7), domains: ["x.com", "tiktok.com"]),
                 selection: FamilyActivitySelection()),
            Rule(id: social, plan: RulePlan(name: "Social", kind: .limit, days: Set(1...7), limitMinutes: 30),
                 selection: FamilyActivitySelection()),
            Rule(id: games, plan: RulePlan(name: "Games", kind: .limit, days: [2, 3, 4, 5, 6], limitMinutes: 45),
                 selection: FamilyActivitySelection()),
            Rule(id: shorts, plan: RulePlan(name: "Shorts", kind: .timeout, days: Set(1...7), limitMinutes: 20,
                                            breakMinutes: 10, strict: false),
                 selection: FamilyActivitySelection()),
        ]
        if shot == "session" {
            s.session = FocusSession(startedAt: now.addingTimeInterval(-15 * 60), endsAt: now.addingTimeInterval(75 * 60),
                                     selection: FamilyActivitySelection(), domains: [])
        }
        return s
    }

    /// Generic stand-ins for app icons (real icons only exist on a device with Screen Time access).
    static func icons(for name: String) -> [(symbol: String, hue: Double)] {
        switch name {
        case "Study": return [("play.rectangle.fill", 0.0), ("camera.fill", 0.85), ("bubble.left.and.bubble.right.fill", 0.58)]
        case "Sleep": return [("play.rectangle.fill", 0.0), ("music.note", 0.95), ("gamecontroller.fill", 0.75)]
        case "Social": return [("camera.fill", 0.85), ("bubble.left.and.bubble.right.fill", 0.58), ("at", 0.6), ("person.2.fill", 0.12)]
        case "Games": return [("gamecontroller.fill", 0.75), ("dice.fill", 0.33)]
        case "Shorts": return [("play.rectangle.fill", 0.0), ("music.note", 0.95), ("camera.fill", 0.85)]
        default: return []
        }
    }

    static func reachedAt(_ id: UUID) -> Date? { id == games ? now.addingTimeInterval(-1800) : nil }
    static func level(_ id: UUID) -> Int { id == social ? 5 : id == games ? 10 : 0 }
    static func breakUntil(_ id: UUID) -> Date? { id == shorts ? now.addingTimeInterval(6 * 60) : nil }
    static func usage(_ id: UUID) -> UsageSummary {
        switch id {
        case social: UsageSummary(minutes: 17, limit: 30)
        case games: UsageSummary(minutes: 45, limit: 45)
        default: UsageSummary(minutes: 48)
        }
    }
}
#endif
