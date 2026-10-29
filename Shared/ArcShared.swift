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
    /// Strict lock: can't be stopped early (when Strict lock is on in Settings).
    var strict = true

    init(id: UUID = UUID(), startedAt: Date, endsAt: Date, selection: FamilyActivitySelection, domains: [String], strict: Bool = true) {
        self.id = id; self.startedAt = startedAt; self.endsAt = endsAt; self.selection = selection
        self.domains = domains; self.strict = strict
    }

    enum CodingKeys: String, CodingKey { case id, startedAt, endsAt, selection, domains, strict }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endsAt = try c.decode(Date.self, forKey: .endsAt)
        selection = try c.decode(FamilyActivitySelection.self, forKey: .selection)
        domains = (try? c.decode([String].self, forKey: .domains)) ?? []
        strict = (try? c.decode(Bool.self, forKey: .strict)) ?? true
    }
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
    /// No app (Arc Lock included) can be deleted while this is on. On by default; switching it off waits until the
    /// strict blocks running or counting then have reset or ended (`deletionProtectionOffAt`).
    var deletionProtection = true
    var deletionProtectionOffAt: Date?
    /// Strict lock (global): blocks marked Strict lock can't be stopped or loosened while they run. On by default.
    /// Switching it off applies at once; see `strictUntil`.
    var strictLock = true
    /// Saved by older versions: a switch-off that was waiting for midnight. Housekeeping applies it the new way
    /// (see `strictUntil`).
    var strictLockOffAt: Date?
    /// After Strict lock was switched off: the blocks that keep it (rule or Block-now id → until when). Each one that
    /// was running or counting keeps its lock until its own reset, or until its run ends (StrictHold).
    var strictUntil: [String: Date] = [:]
    /// Rule id → store slot. iOS allows an app 50 named stores in total, so rules reuse a fixed pool of slots.
    var slots: [String: Int] = [:]
    /// Set when some saved rule couldn't be read (never saved itself): the raw data is kept before overwriting.
    var hadUnreadable = false

    enum CodingKeys: String, CodingKey {
        case rules, session, lockInUntil, lastSessionSelection, lastSessionMinutes, headsUp, onboarded, slots
        case deletionProtection, deletionProtectionOffAt, strictLock, strictLockOffAt, strictUntil
    }

    init() {}

    /// Whether this state may be acted on (shields, monitors, housekeeping) or written back (Core: `SavedState`).
    /// Before the first unlock after a restart iOS can't read the shared state and it loads as never set up; a real
    /// one always is. (Being locked later doesn't matter: once unlocked after a restart, the shared state stays
    /// readable while the iPhone is locked — unlike `UIApplication.isProtectedDataAvailable`, false whenever locked.)
    var isSetUp: Bool { onboarded }

    func slot(of id: UUID) -> Int? { slots[id.uuidString] }

    /// A lock-in makes everything strict. Otherwise a block is strict when it's set to Strict lock and the global
    /// switch is on — or the switch went off while it was running or counting, until that run or period is over.
    func isStrict(_ rule: Rule, now: Date = Date()) -> Bool { isStrict(rule.plan, id: rule.id, now: now) }
    func isStrict(_ plan: RulePlan, id: UUID, now: Date = Date()) -> Bool {
        if Policy.lockInActive(lockInUntil, now: now) { return true }
        guard plan.strict else { return false }
        return strictLock || (strictUntil[id.uuidString] ?? .distantPast) > now
    }
    func isStrict(_ session: FocusSession, now: Date = Date()) -> Bool {
        if Policy.lockInActive(lockInUntil, now: now) { return true }
        guard session.strict else { return false }
        return strictLock || (strictUntil[session.id.uuidString] ?? .distantPast) > now
    }

    /// Turns Strict lock off now. Each strict block that is running or counting keeps its lock until its own reset,
    /// or until its run ends; a strict Block now until it ends. `status` = each block's status at `now`.
    mutating func switchStrictOff(now: Date, calendar: Calendar, status: (Rule) -> RuleStatus) {
        if strictLock {
            var holds: [String: Date] = [:]
            for r in rules {
                if let until = StrictHold.until(r.plan, status: status(r), now: now, calendar: calendar) { holds[r.id.uuidString] = until }
            }
            if let s = session, s.strict, s.endsAt > now { holds[s.id.uuidString] = s.endsAt }
            strictUntil = holds
        }
        strictLock = false
        strictLockOffAt = nil
        strictUntil = strictUntil.filter { $0.value > now }
    }

    /// A break that starts while its time-out still keeps Strict lock (switched off, waiting for its reset) is a
    /// strict run too: it keeps the lock until the break ends, even past the reset. Returns whether the hold moved.
    mutating func holdThroughBreak(_ id: UUID, until end: Date, now: Date) -> Bool {
        guard !strictLock, let held = strictUntil[id.uuidString], held > now, held < end else { return false }
        strictUntil[id.uuidString] = end
        return true
    }

    /// When every strict block that is running or counting now has reset or ended (each at its own time); nil when
    /// none is. Switching deletion protection off waits for this.
    func strictHoldsEnd(now: Date, calendar: Calendar, status: (Rule) -> RuleStatus) -> Date? {
        var ends: [Date] = []
        for r in rules where r.plan.strict && isStrict(r, now: now) {
            guard var until = StrictHold.until(r.plan, status: status(r), now: now, calendar: calendar) else { continue }
            if !strictLock, let held = strictUntil[r.id.uuidString] { until = min(until, held) }
            // a place block running until you leave: its end isn't known (its own shield keeps apps from being
            // deleted while it runs), so it doesn't hold this switch for up to 12 hours
            if r.plan.kind == .place && r.plan.untilLeave { continue }
            ends.append(until)
        }
        if let s = session, s.endsAt > now, isStrict(s, now: now) { ends.append(s.endsAt) }
        return ends.max()
    }

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
        deletionProtection = (try? c.decode(Bool.self, forKey: .deletionProtection)) ?? true
        deletionProtectionOffAt = try? c.decode(Date.self, forKey: .deletionProtectionOffAt)
        strictLock = (try? c.decode(Bool.self, forKey: .strictLock)) ?? true
        strictLockOffAt = try? c.decode(Date.self, forKey: .strictLockOffAt)
        strictUntil = (try? c.decode([String: Date].self, forKey: .strictUntil)) ?? [:]
    }
}

extension RulePlan {
    /// The block's name as text: what the user typed, or else its place, its first website, or what kind of block it
    /// is. (With no name typed, the app shows the first chosen app's name instead — iOS can draw it, see BlockName,
    /// but never hands it to Arc Lock as text.)
    var displayName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        if kind == .place, let p = places.first?.name, !p.isEmpty { return p }
        if let d = domains.first { return d }
        switch kind {
        case .schedule: return L("Schedule")
        case .limit: return L("Daily limit")
        case .timeout: return L("Time-out")
        case .place: return L("Place block")
        }
    }
    var hasName: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Decodes an element if it can, so one unreadable rule doesn't take the others with it.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

enum StateStore {
    private static let key = "state.v1"
    /// Whether a saved state is there to read: false on a fresh install, and before the first unlock after a restart
    /// (every read of the shared data comes back empty then).
    static var isSaved: Bool { AppGroup.defaults.object(forKey: key) != nil }
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
    /// Read-modify-write on the freshest copy (the app and the monitor extension both write). A state that isn't set
    /// up — what an unreadable one looks like before the first unlock after a restart — is never changed or written
    /// back, except by the app setting itself up with the iPhone unlocked (`settingUp`).
    @discardableResult
    static func update(settingUp: @autoclosure () -> Bool = false, _ change: (inout ArcState) -> Void) -> ArcState {
        SavedState.update(load: load, save: save, isSetUp: \.isSetUp, settingUp: settingUp(), change)
    }
    /// Whether a set-up state is saved, read from the file itself rather than through UserDefaults: a process that
    /// read the shared data before the first unlock after a restart can keep getting it empty from UserDefaults even
    /// after the unlock. True only when the file shows one; anything unreadable counts as not set up, so setting up
    /// is never blocked for good. Read only — iOS owns and writes the file. Needs the iPhone unlocked since the restart.
    static var setUpOnDisk: Bool {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id),
              let file = try? Data(contentsOf: dir.appendingPathComponent("Library/Preferences/\(AppGroup.id).plist")),
              let prefs = try? PropertyListSerialization.propertyList(from: file, format: nil) as? [String: Any],
              let data = prefs[key] as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json[ArcState.CodingKeys.onboarded.stringValue] as? Bool == true
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
    /// The level in the block's current period (0 when nothing was recorded since its last reset).
    static func level(_ id: UUID, period: Date) -> Int {
        guard let m = get(id), abs(m.day.timeIntervalSince(period)) < 1 else { return 0 }
        return m.level
    }
    static func reachedAt(_ id: UUID) -> Date? {
        guard let m = get(id), m.level >= 10 else { return nil }
        return m.at
    }
    /// `period` = when the block's current period began (Period.start); marks from an earlier period don't count.
    static func raise(_ id: UUID, to level: Int, now: Date = Date(), period: Date) {
        if let m = get(id), abs(m.day.timeIntervalSince(period)) < 1, m.level >= level { return }
        if let d = try? JSONEncoder().encode(UsageMark(day: period, level: level, at: now)) {
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
    /// The credit in the block's current period (0 when none or from an earlier one).
    static func today(_ id: UUID, period: Date) -> Int {
        guard let d = AppGroup.defaults.data(forKey: key(id)), let c = try? JSONDecoder().decode(UsageCredit.self, from: d),
              abs(c.day.timeIntervalSince(period)) < 1 else { return 0 }
        return c.minutes
    }
    static func set(_ id: UUID, minutes: Int, period: Date) {
        guard minutes > 0 else { clear(id); return }
        if let d = try? JSONEncoder().encode(UsageCredit(day: period, minutes: minutes)) {
            AppGroup.defaults.set(d, forKey: key(id))
        }
    }
    static func clear(_ id: UUID) { AppGroup.defaults.removeObject(forKey: key(id)) }
}

/// The day a limit's count was last restarted by an edit. iOS restarts its count on every such edit and the
/// carried-over use is rounded down to a tenth, so only one restart a period is allowed; later ones wait for its
/// next reset.
enum Restarts {
    private static func key(_ id: UUID) -> String { "restart.\(id.uuidString)" }
    /// Whether the count was restarted since the block's last reset (`period` = Period.start).
    static func happenedToday(_ id: UUID, period: Date, now: Date = Date()) -> Bool {
        guard let d = AppGroup.defaults.object(forKey: key(id)) as? Date else { return false }
        return d >= period && d <= now
    }
    static func mark(_ id: UUID, now: Date = Date()) { AppGroup.defaults.set(now, forKey: key(id)) }
    static func clear(_ id: UUID) { AppGroup.defaults.removeObject(forKey: key(id)) }
}

/// A time-out's current break, written by the monitor extension when the use threshold passes.
struct BreakMark: Codable, Equatable {
    var until: Date
}

enum Breaks {
    private static func key(_ id: UUID) -> String { "break.\(id.uuidString)" }
    static func get(_ id: UUID) -> BreakMark? {
        guard let d = AppGroup.defaults.data(forKey: key(id)) else { return nil }
        return try? JSONDecoder().decode(BreakMark.self, from: d)
    }
    static func until(_ id: UUID) -> Date? { get(id)?.until }
    static func set(_ id: UUID, until: Date) {
        if let d = try? JSONEncoder().encode(BreakMark(until: until)) { AppGroup.defaults.set(d, forKey: key(id)) }
    }
    static func clear(_ id: UUID) { AppGroup.defaults.removeObject(forKey: key(id)) }
}

/// Place blocks: the current visit to each block's place, written by the app when iOS reports arriving or leaving
/// (and read by the extensions, which can't see the location themselves).
enum PlaceVisits {
    private static func key(_ id: UUID) -> String { "visit.\(id.uuidString)" }
    static func get(_ id: UUID) -> PlaceVisit? {
        guard let d = AppGroup.defaults.data(forKey: key(id)) else { return nil }
        return try? JSONDecoder().decode(PlaceVisit.self, from: d)
    }
    static func set(_ id: UUID, _ visit: PlaceVisit?) {
        guard let visit, let d = try? JSONEncoder().encode(visit) else { clear(id); return }
        AppGroup.defaults.set(d, forKey: key(id))
    }
    static func clear(_ id: UUID) { AppGroup.defaults.removeObject(forKey: key(id)) }
}

/// Blocks that aren't strict and were stopped by hand: no shield until the date (when the block would end).
enum Stops {
    private static func key(_ id: String) -> String { "stopped.\(id)" }
    static func until(_ id: UUID) -> Date? { AppGroup.defaults.object(forKey: key(id.uuidString)) as? Date }
    static func set(_ id: UUID, until: Date) { AppGroup.defaults.set(until, forKey: key(id.uuidString)) }
    static func clear(_ id: UUID) { AppGroup.defaults.removeObject(forKey: key(id.uuidString)) }
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
    /// A time-out's break: a one-off monitor whose end lifts the break and restarts the count.
    static func breakActivity(_ rule: UUID) -> DeviceActivityName { .init("brk.\(rule.uuidString)") }
    static func breakRuleID(_ activity: DeviceActivityName) -> UUID? {
        guard activity.rawValue.hasPrefix("brk.") else { return nil }
        return UUID(uuidString: String(activity.rawValue.dropFirst(4)))
    }
    /// A place block set to end after a time: a one-off monitor whose end lifts it, even if Arc Lock stays closed.
    static func placeActivity(_ rule: UUID) -> DeviceActivityName { .init("plc.\(rule.uuidString)") }
    static func placeRuleID(_ activity: DeviceActivityName) -> UUID? {
        guard activity.rawValue.hasPrefix("plc.") else { return nil }
        return UUID(uuidString: String(activity.rawValue.dropFirst(4)))
    }
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
    /// change waiting for its reset.
    static let clockStore = ManagedSettingsStore.Name("clock")
    /// Deletion protection (always-on, separate from blocks).
    static let guardStore = ManagedSettingsStore.Name("guard")
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
