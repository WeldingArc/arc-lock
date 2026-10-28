// Debug builds only: sample blocks for screenshots and UI checks in the simulator, without touching Screen Time.
//   xcrun simctl launch booted io.github.weldingarc.arclock -demo YES -shot home|editor|limit|timeout|timeouts|blocknow|settings|lockin|guide|onboarding
#if DEBUG
import FamilyControls
import Foundation

enum Demo {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "demo") }
    static var shot: String? { UserDefaults.standard.string(forKey: "shot") }
    /// The tab a screenshot starts on.
    static var tab: AppTab {
        switch shot {
        case "blocks", "limits", "timeouts", "editor", "limit", "timeout", "places", "place", "placenew", "placepicker": .blocks
        case "settings", "appearance", "guide": .settings
        default: .home
        }
    }

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
    static let library = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!

    /// Sample names in the phone's language (Korean screenshots get Korean names).
    private static var korean: Bool { Locale.preferredLanguages.first?.hasPrefix("ko") == true }
    private static func n(_ en: String, _ ko: String) -> String { korean ? ko : en }

    static func state() -> ArcState {
        var s = ArcState()
        s.onboarded = !(shot ?? "").hasPrefix("onboarding")
        s.rules = [
            Rule(id: study, plan: RulePlan(name: n("Study", "공부"), kind: .schedule, start: TimeOfDay(9, 0), end: TimeOfDay(17, 0),
                                           days: [2, 3, 4, 5, 6], domains: ["youtube.com", "instagram.com", "reddit.com"]),
                 selection: FamilyActivitySelection()),
            Rule(id: sleep, plan: RulePlan(name: n("Sleep", "수면"), kind: .schedule, start: TimeOfDay(23, 0), end: TimeOfDay(7, 0),
                                           days: Set(1...7), domains: ["x.com", "tiktok.com"]),
                 selection: FamilyActivitySelection()),
            Rule(id: social, plan: RulePlan(name: n("Social", "SNS"), kind: .limit, days: Set(1...7), limitMinutes: 30),
                 selection: FamilyActivitySelection()),
            Rule(id: games, plan: RulePlan(name: n("Games", "게임"), kind: .limit, days: [2, 3, 4, 5, 6], limitMinutes: 45),
                 selection: FamilyActivitySelection()),
            Rule(id: shorts, plan: RulePlan(name: n("Shorts", "쇼츠"), kind: .timeout, days: Set(1...7), limitMinutes: 20,
                                            breakMinutes: 10, strict: false, resetAt: TimeOfDay(4, 0)),
                 selection: FamilyActivitySelection()),
            Rule(id: library, plan: RulePlan(name: n("Library", "도서관"), kind: .place, days: [2, 3, 4, 5, 6],
                                             places: [PlaceSpot(latitude: 37.5640, longitude: 126.9370, radius: 150, name: n("Central Library", "중앙도서관")),
                                                      PlaceSpot(latitude: 37.5585, longitude: 126.9425, radius: 120, name: n("Study Cafe", "스터디 카페"))],
                                             untilLeave: true),
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
        case "Study", "공부": return [("play.rectangle.fill", 0.0), ("camera.fill", 0.85), ("bubble.left.and.bubble.right.fill", 0.58)]
        case "Sleep", "수면": return [("play.rectangle.fill", 0.0), ("music.note", 0.95), ("gamecontroller.fill", 0.75)]
        case "Social", "SNS": return [("camera.fill", 0.85), ("bubble.left.and.bubble.right.fill", 0.58), ("at", 0.6), ("person.2.fill", 0.12)]
        case "Games", "게임": return [("gamecontroller.fill", 0.75), ("dice.fill", 0.33)]
        case "Shorts", "쇼츠": return [("play.rectangle.fill", 0.0), ("music.note", 0.95), ("camera.fill", 0.85)]
        case "Library", "도서관": return [("gamecontroller.fill", 0.75), ("play.rectangle.fill", 0.0), ("bubble.left.and.bubble.right.fill", 0.58)]
        default: return []
        }
    }

    static func reachedAt(_ id: UUID) -> Date? { id == games ? now.addingTimeInterval(-1800) : nil }
    static func level(_ id: UUID) -> Int { id == social ? 5 : id == games ? 10 : 0 }
    static func breakUntil(_ id: UUID) -> Date? { id == shorts ? now.addingTimeInterval(6 * 60) : nil }
    /// At the library since 9:50, until you leave.
    static func visit(_ id: UUID) -> PlaceVisit? {
        id == library ? PlaceVisit(inside: true, started: now.addingTimeInterval(-40 * 60)) : nil
    }
    static func usage(_ id: UUID) -> UsageSummary {
        switch id {
        case social: UsageSummary(minutes: 17, limit: 30)
        case games: UsageSummary(minutes: 45, limit: 45)
        default: UsageSummary(minutes: 48)
        }
    }
}
#endif
