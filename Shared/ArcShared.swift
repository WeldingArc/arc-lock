// State, names and storage shared by the app and its extensions (App Group defaults).
// The monitor extension runs while the app is closed, so everything it needs lives here.
import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings

typealias Rule = RuleRecord<FamilyActivitySelection>
typealias RuleChange = PendingChange<FamilyActivitySelection>

enum AppGroup {
    static let id = "group.io.github.weldingarc.arclock"
    static let defaults: UserDefaults = UserDefaults(suiteName: id) ?? .standard
}

/// "Block now": one-off block that ends on its own.
struct FocusSession: Codable, Equatable {
    var id = UUID()
    var startedAt: Date
    var endsAt: Date
    var selection: FamilyActivitySelection
    var domains: [String]
}

struct ArcState: Codable, Equatable {
    var rules: [Rule] = []
    var session: FocusSession?
    /// While set and in the future, every rule is read-only and no app can be deleted.
    var lockInUntil: Date?
    var lastSessionSelection: FamilyActivitySelection?
    var lastSessionMinutes = 60
    var headsUp = true
    var onboarded = false
    /// Rule id → store slot. iOS allows an app 50 named stores in total, so rules reuse a fixed pool of slots.
    var slots: [String: Int] = [:]
    /// Set when some saved rule couldn't be read (never saved itself): the raw data is kept before overwriting.
    var hadUnreadable = false

    enum CodingKeys: String, CodingKey {
        case rules, session, lockInUntil, lastSessionSelection, lastSessionMinutes, headsUp, onboarded, slots
    }

    init() {}

    func slot(of id: UUID) -> Int? { slots[id.uuidString] }

    /// Gives every rule a slot (lowest free first) and frees slots of deleted rules.
    mutating func assignSlots() {
        slots = Slots.assign(slots, ruleIDs: rules.map(\.id.uuidString), count: Names.slotCount)
    }

    // Decode field by field, so a missing or unreadable setting falls back to its default instead of failing the rest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let all = try? c.decode([Rule].self, forKey: .rules) {
            rules = all
        } else {
            // keep every rule that can be read instead of dropping them all
            rules = ((try? c.decode([Lossy<Rule>].self, forKey: .rules)) ?? []).compactMap(\.value)
            hadUnreadable = c.contains(.rules)
        }
        session = try? c.decode(FocusSession.self, forKey: .session)
        lockInUntil = try? c.decode(Date.self, forKey: .lockInUntil)
        lastSessionSelection = try? c.decode(FamilyActivitySelection.self, forKey: .lastSessionSelection)
        lastSessionMinutes = (try? c.decode(Int.self, forKey: .lastSessionMinutes)) ?? 60
        headsUp = (try? c.decode(Bool.self, forKey: .headsUp)) ?? true
        onboarded = (try? c.decode(Bool.self, forKey: .onboarded)) ?? false
        slots = (try? c.decode([String: Int].self, forKey: .slots)) ?? [:]
    }
}

/// Decodes an element if it can, so one unreadable rule doesn't take the others with it.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

enum StateStore {
    private static let key = "state.v1"
    static func load() -> ArcState {
        guard let data = AppGroup.defaults.data(forKey: key) else { return ArcState() }
        DecodeReport.droppedPending = 0
        let s = try? JSONDecoder().decode(ArcState.self, from: data)
        if s == nil || s?.hadUnreadable == true || DecodeReport.droppedPending > 0 {
            // never silently lose someone's blocks: keep the unreadable copy before anything overwrites it
            if AppGroup.defaults.data(forKey: key + ".unreadable") == nil {
                AppGroup.defaults.set(data, forKey: key + ".unreadable")
            }
        }
        return s ?? ArcState()
    }
    static func save(_ state: ArcState) {
        if let data = try? JSONEncoder().encode(state) { AppGroup.defaults.set(data, forKey: key) }
    }
    /// Read-modify-write on the freshest copy (the app and the monitor extension both write).
    @discardableResult
    static func update(_ change: (inout ArcState) -> Void) -> ArcState {
        var s = load()
        change(&s)
        save(s)
        return s
    }
}

/// Progress of a daily limit today in tenths (10 = used up). Written by the monitor extension, and by the app when
/// an edit carries today's use over to a stricter limit.
struct UsageMark: Codable, Equatable {
    var day: Date
    var level: Int
    var at: Date
}

enum Marks {
    private static func key(_ id: UUID) -> String { "mark.\(id.uuidString)" }
    static func get(_ id: UUID) -> UsageMark? {
        guard let d = AppGroup.defaults.data(forKey: key(id)) else { return nil }
        return try? JSONDecoder().decode(UsageMark.self, from: d)
    }
    /// Today's level (0 when nothing was recorded today).
    static func level(_ id: UUID, now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard let m = get(id), calendar.isDate(m.day, inSameDayAs: now) else { return 0 }
        return m.level
    }
    static func reachedAt(_ id: UUID) -> Date? {
        guard let m = get(id), m.level >= 10 else { return nil }
        return m.at
    }
    static func raise(_ id: UUID, to level: Int, now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        if let m = get(id), calendar.isDate(m.day, inSameDayAs: now), m.level >= level { return }
        if let d = try? JSONEncoder().encode(UsageMark(day: today, level: level, at: now)) {
            AppGroup.defaults.set(d, forKey: key(id))
        }
    }
    static func clear(_ id: UUID) { AppGroup.defaults.removeObject(forKey: key(id)) }
}

/// Minutes of today's use carried over when a limit is changed mid-day (its monitor restarts its count).
struct UsageCredit: Codable, Equatable {
    var day: Date
    var minutes: Int
}

enum Credits {
    private static func key(_ id: UUID) -> String { "credit.\(id.uuidString)" }
    /// Today's credit for a rule (0 when none or from an earlier day).
    static func today(_ id: UUID, now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard let d = AppGroup.defaults.data(forKey: key(id)), let c = try? JSONDecoder().decode(UsageCredit.self, from: d),
              calendar.isDate(c.day, inSameDayAs: now) else { return 0 }
        return c.minutes
    }
    static func set(_ id: UUID, minutes: Int, now: Date = Date(), calendar: Calendar = .current) {
        guard minutes > 0 else { clear(id); return }
        if let d = try? JSONEncoder().encode(UsageCredit(day: calendar.startOfDay(for: now), minutes: minutes)) {
            AppGroup.defaults.set(d, forKey: key(id))
        }
    }
    static func clear(_ id: UUID) { AppGroup.defaults.removeObject(forKey: key(id)) }
}

/// The day a limit's count was last restarted by an edit. iOS restarts its count on every such edit and the
/// carried-over use is rounded down to a tenth, so only one restart a day is allowed; later ones wait for midnight.
enum Restarts {
    private static func key(_ id: UUID) -> String { "restart.\(id.uuidString)" }
    static func happenedToday(_ id: UUID, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let d = AppGroup.defaults.object(forKey: key(id)) as? Date else { return false }
        return calendar.isDate(d, inSameDayAs: now)
    }
    static func mark(_ id: UUID, now: Date = Date()) { AppGroup.defaults.set(now, forKey: key(id)) }
    static func clear(_ id: UUID) { AppGroup.defaults.removeObject(forKey: key(id)) }
}

enum Names {
    static let session = DeviceActivityName("session")
    static let daily = DeviceActivityName("daily")
    static let limitEvent = DeviceActivityEvent.Name("limit")
    /// Usage events: "p1"…"p9" = tenths of the limit, "limit" = the limit itself (tenth 10).
    static func event(tenth: Int) -> DeviceActivityEvent.Name { tenth >= 10 ? limitEvent : .init("p\(tenth)") }
    static func tenth(of event: DeviceActivityEvent.Name) -> Int? {
        if event == limitEvent { return 10 }
        guard event.rawValue.hasPrefix("p") else { return nil }
        return Int(event.rawValue.dropFirst())
    }

    static func activity(_ rule: UUID) -> DeviceActivityName { .init("rule.\(rule.uuidString)") }
    static func ruleID(_ activity: DeviceActivityName) -> UUID? {
        guard activity.rawValue.hasPrefix("rule.") else { return nil }
        return UUID(uuidString: String(activity.rawValue.dropFirst(5)))
    }

    /// A fixed pool of store names (see ArcState.slots); with the session and lock-in stores that's 20 of iOS's 50.
    static let slotCount = 18
    static func store(slot: Int) -> ManagedSettingsStore.Name { .init("slot.\(slot)") }
    static let sessionStore = ManagedSettingsStore.Name("session")
    static let lockInStore = ManagedSettingsStore.Name("lockin")
    /// Keeps the clock automatic while any block is switched on, so it can't be set forward past a block or a
    /// change waiting for midnight.
    static let clockStore = ManagedSettingsStore.Name("clock")
}

extension FamilyActivitySelection {
    var itemCount: Int { applicationTokens.count + categoryTokens.count + webDomainTokens.count }
    var isEmpty: Bool { itemCount == 0 }
    /// Items in `old` that are missing here.
    func lost(from old: FamilyActivitySelection) -> Bool {
        !applicationTokens.isSuperset(of: old.applicationTokens) ||
        !categoryTokens.isSuperset(of: old.categoryTokens) ||
        !webDomainTokens.isSuperset(of: old.webDomainTokens)
    }
    func gained(over old: FamilyActivitySelection) -> Bool { old.lost(from: self) }
}

/// Plain-text strings for code outside SwiftUI (extensions, notifications). Keys live in */Localizable.strings.
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }
func L(_ key: String, _ args: CVarArg...) -> String { String(format: NSLocalizedString(key, comment: ""), arguments: args) }

enum Fmt {
    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: d)
    }
    /// "17:00", "midnight", "Tue 07:00" or "Oct 20" — as short as is still unambiguous.
    static func moment(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(d, inSameDayAs: now) { return time(d) }
        if d == ScheduleMath.startOfNextDay(after: now, calendar: calendar) { return L("midnight") }
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate(d.timeIntervalSince(now) < 6 * 86400 ? "EEEjmm" : "MMMd")
        return f.string(from: d)
    }
    /// The last day of a span that ends at a midnight ("through Mon, Oct 19").
    static func lastDay(endingAt d: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return f.string(from: d.addingTimeInterval(-1))
    }
}
