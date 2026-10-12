// The rules of Arc Lock, free of Apple's Screen Time frameworks so they can be unit-tested on a Mac:
// when a block runs, when a daily limit counts, and what may be changed when.
// The app and every extension compile this file; Tests/CoreTests.swift exercises it.
import Foundation

// MARK: - Plan

public struct TimeOfDay: Codable, Hashable, Comparable, Sendable {
    public var hour: Int
    public var minute: Int
    public init(_ hour: Int, _ minute: Int) { self.hour = hour; self.minute = minute }
    public var minutes: Int { hour * 60 + minute }
    public var components: DateComponents { DateComponents(hour: hour, minute: minute) }
    public static func < (a: TimeOfDay, b: TimeOfDay) -> Bool { a.minutes < b.minutes }
}

public enum RuleKind: String, Codable, CaseIterable, Sendable { case schedule, limit }

/// Everything about a block except the chosen apps (Apple's opaque tokens live next to it, in the app).
public struct RulePlan: Codable, Hashable, Sendable {
    public var name: String
    public var kind: RuleKind
    public var isOn: Bool
    public var start: TimeOfDay
    public var end: TimeOfDay
    /// Calendar weekdays, 1 = Sunday … 7 = Saturday. A window that runs past midnight belongs to the day it starts.
    public var days: Set<Int>
    public var limitMinutes: Int
    /// Websites typed by address (schedules only — Screen Time can't measure time spent on them).
    public var domains: [String]

    public init(name: String = "", kind: RuleKind = .schedule, isOn: Bool = true,
                start: TimeOfDay = TimeOfDay(9, 0), end: TimeOfDay = TimeOfDay(17, 0),
                days: Set<Int> = Set(1...7), limitMinutes: Int = 30, domains: [String] = []) {
        self.name = name; self.kind = kind; self.isOn = isOn; self.start = start; self.end = end
        self.days = days; self.limitMinutes = limitMinutes; self.domains = domains
    }
}

public enum Limits {
    /// DeviceActivity refuses schedules shorter than 15 minutes.
    public static let minimumWindowMinutes = 15
    public static let limitMinutes = 5...480
    public static let sessionMinutes = 15...(12 * 60)
    /// A schedule must leave time between windows, or it could never be changed again. 22 h leaves a 2-hour gap,
    /// which is still at least an hour on the day the clocks spring forward.
    public static let maxWindowMinutes = 22 * 60
    /// All schedules together must leave a free stretch this long at least once in every day.
    public static let minimumFreeMinutes = 60
    /// iOS shields nothing when a set holds more than 50 tokens (one report says 49); stay safely under.
    public static let maxApps = 49
    public static let maxDomains = 49
    /// DeviceActivity monitors at most 20 activities per app (and its extensions): rules + Block now + housekeeping.
    public static let maxActivities = 20
    public static let reservedActivities = 2
    /// A limit's thresholds can't be real sooner than this after counting starts (iOS sometimes fires right after
    /// a monitor is registered — a known bug — and use can't outrun the clock).
    public static let minimumEventDelay: TimeInterval = 60
}

// MARK: - Time math

public enum ScheduleMath {
    /// Minutes from start to end; an end at or before the start means the window runs past midnight.
    public static func length(_ start: TimeOfDay, _ end: TimeOfDay) -> Int {
        let d = end.minutes - start.minutes
        return d > 0 ? d : d + 24 * 60
    }

    public static func isOvernight(_ plan: RulePlan) -> Bool { plan.end.minutes <= plan.start.minutes }

    /// The window that starts on the day of `day` (any time that day), if that weekday is selected.
    /// Ends are wall-clock times, like DeviceActivity's own schedules (right across daylight-saving changes).
    public static func window(startingOn day: Date, plan: RulePlan, calendar: Calendar) -> DateInterval? {
        let dayStart = calendar.startOfDay(for: day)
        guard plan.days.contains(calendar.component(.weekday, from: dayStart)),
              let s = moment(plan.start, on: dayStart, calendar: calendar)
        else { return nil }
        let endDay = isOvernight(plan) ? calendar.date(byAdding: .day, value: 1, to: dayStart)! : dayStart
        guard let e = moment(plan.end, on: calendar.startOfDay(for: endDay), calendar: calendar), e > s else { return nil }
        return DateInterval(start: s, end: e)
    }

    /// A wall-clock time on a given day. A time the clocks skip that day (e.g. 02:00 when they spring forward)
    /// becomes the same amount of real time after midnight, so it never lands on another day.
    static func moment(_ t: TimeOfDay, on dayStart: Date, calendar: Calendar) -> Date? {
        if let d = calendar.date(bySettingHour: t.hour, minute: t.minute, second: 0, of: dayStart),
           calendar.isDate(d, inSameDayAs: dayStart) { return d }
        return calendar.date(byAdding: .minute, value: t.minutes, to: dayStart)
    }

    /// The schedule window that contains `date`, if any.
    public static func window(containing date: Date, plan: RulePlan, calendar: Calendar) -> DateInterval? {
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date)),
                  let w = window(startingOn: day, plan: plan, calendar: calendar) else { continue }
            if w.start <= date && date < w.end { return w }
        }
        return nil
    }

    /// The next window that starts after `date` (within the coming 8 days).
    public static func nextWindow(after date: Date, plan: RulePlan, calendar: Calendar) -> DateInterval? {
        guard !plan.days.isEmpty else { return nil }
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: date)),
                  let w = window(startingOn: day, plan: plan, calendar: calendar) else { continue }
            if w.start > date { return w }
        }
        return nil
    }

    public static func startOfNextDay(after date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))!
    }
}

// MARK: - Status

public enum RuleStatus: Equatable, Sendable {
    case off
    /// A schedule between windows (`next` = when it starts again).
    case waiting(next: Date?)
    case running(until: Date)
    /// A daily limit counting today's use.
    case counting
    /// A daily limit on a day that isn't selected.
    case resting
    case reached(until: Date)

    public var isBlocking: Bool {
        switch self { case .running, .reached: return true; default: return false }
    }
    public var blockingUntil: Date? {
        switch self { case .running(let u), .reached(let u): return u; default: return nil }
    }
}

public enum Status {
    /// `reachedAt` is when the monitor extension last saw this limit's threshold.
    public static func of(_ plan: RulePlan, now: Date, reachedAt: Date?, calendar: Calendar) -> RuleStatus {
        guard plan.isOn else { return .off }
        switch plan.kind {
        case .schedule:
            if let w = ScheduleMath.window(containing: now, plan: plan, calendar: calendar) { return .running(until: w.end) }
            return .waiting(next: ScheduleMath.nextWindow(after: now, plan: plan, calendar: calendar)?.start)
        case .limit:
            guard plan.days.contains(calendar.component(.weekday, from: now)) else { return .resting }
            if let r = reachedAt, calendar.isDate(r, inSameDayAs: now) {
                return .reached(until: ScheduleMath.startOfNextDay(after: now, calendar: calendar))
            }
            return .counting
        }
    }
}

// MARK: - What may change when

public enum LockReason: String, Codable, Sendable { case running, reached, session, lockIn }

public enum EditAccess: Equatable, Sendable {
    /// Any change applies now.
    case free
    /// A daily limit that is counting today: stricter changes apply now, looser ones from `loosenFrom` (next midnight).
    case stricterOnly(loosenFrom: Date)
    /// Read-only until `until`.
    case locked(until: Date, reason: LockReason)
}

public enum Policy {
    public static func access(status: RuleStatus, lockInUntil: Date?, now: Date, calendar: Calendar) -> EditAccess {
        var lock: (Date, LockReason)?
        switch status {
        case .running(let u): lock = (u, .running)
        case .reached(let u): lock = (u, .reached)
        default: break
        }
        if let l = lockInUntil, l > now, l > (lock?.0 ?? .distantPast) { lock = (l, .lockIn) }
        if let (until, reason) = lock { return .locked(until: until, reason: reason) }
        if case .counting = status {
            return .stricterOnly(loosenFrom: ScheduleMath.startOfNextDay(after: now, calendar: calendar))
        }
        return .free
    }

    public static func lockInActive(_ until: Date?, now: Date) -> Bool { (until ?? .distantPast) > now }
}

public enum ChangeDirection: Equatable, Sendable { case same, stricter, looser }

public enum Change {
    /// Compares two plans; `selectionLost`/`selectionGained` describe the app/website tokens (compared by the app).
    public static func direction(from old: RulePlan, to new: RulePlan,
                                 selectionLost: Bool = false, selectionGained: Bool = false) -> ChangeDirection {
        if old.kind != new.kind { return .looser }           // a different kind of block replaces this one
        var looser = selectionLost, stricter = selectionGained
        if old.isOn && !new.isOn { looser = true }
        if !old.isOn && new.isOn { stricter = true }
        if !new.days.isSuperset(of: old.days) { looser = true }
        if !old.days.isSuperset(of: new.days) { stricter = true }
        let oldDomains = Set(old.domains), newDomains = Set(new.domains)
        if !newDomains.isSuperset(of: oldDomains) { looser = true }
        if !oldDomains.isSuperset(of: newDomains) { stricter = true }
        switch new.kind {
        case .limit:
            if new.limitMinutes > old.limitMinutes { looser = true }
            if new.limitMinutes < old.limitMinutes { stricter = true }
        case .schedule:
            if new.start != old.start || new.end != old.end {
                // a window that covers the old one is stricter; anything else frees some time
                if covers(new, old) { stricter = true } else { looser = true }
            }
        }
        if looser { return .looser }
        return stricter ? .stricter : .same
    }

    /// Whether `a`'s daily window contains all of `b`'s (minute-of-day ranges, overnight aware).
    static func covers(_ a: RulePlan, _ b: RulePlan) -> Bool {
        func minutes(_ p: RulePlan) -> Set<Int> {
            let n = ScheduleMath.length(p.start, p.end)
            return Set((0..<n).map { (p.start.minutes + $0) % (24 * 60) })
        }
        return minutes(a).isSuperset(of: minutes(b))
    }
}

// MARK: - Checks shown in the editor

public enum PlanProblem: Equatable, Sendable {
    case noName, nothingChosen, noDays, windowTooShort, windowTooLong, limitOutOfRange, tooManyApps, tooManyDomains, badDomain(String)
}

public enum Validate {
    public static func problems(_ plan: RulePlan, appCount: Int, hasSelection: Bool, webTokenCount: Int = 0) -> [PlanProblem] {
        var out: [PlanProblem] = []
        if plan.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(.noName) }
        if !hasSelection && (plan.kind == .limit || plan.domains.isEmpty) { out.append(.nothingChosen) }
        if plan.days.isEmpty { out.append(.noDays) }
        switch plan.kind {
        case .schedule:
            let length = ScheduleMath.length(plan.start, plan.end)
            if length < Limits.minimumWindowMinutes { out.append(.windowTooShort) }
            if length > Limits.maxWindowMinutes { out.append(.windowTooLong) }
        case .limit:
            if !Limits.limitMinutes.contains(plan.limitMinutes) { out.append(.limitOutOfRange) }
        }
        // iOS silently shields nothing when a set holds more than 50 tokens
        if appCount > Limits.maxApps { out.append(.tooManyApps) }
        if webTokenCount > Limits.maxDomains { out.append(.tooManyDomains) }
        if plan.domains.count > Limits.maxDomains { out.append(.tooManyDomains) }
        for d in plan.domains where Domains.normalize(d) != d { out.append(.badDomain(d)) }
        return out
    }
}

// MARK: - Websites typed by address

public enum Domains {
    /// "https://www.YouTube.com/watch?v=1" → "youtube.com". Returns nil when it doesn't look like a web address.
    public static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let i = s.firstIndex(where: { "/?#".contains($0) }) { s = String(s[..<i]) }
        if let at = s.lastIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[..<colon]) }
        while s.hasSuffix(".") { s.removeLast() }
        if s.hasPrefix("www.") { s.removeFirst(4) }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")
        let labels = s.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, s.count <= 253,
              s.allSatisfy({ allowed.contains($0) || !$0.isASCII }),
              labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }),
              labels.last!.count >= 2, !labels.last!.allSatisfy(\.isNumber)
        else { return nil }
        return s
    }
}

// MARK: - Rules with Apple's tokens (generic so the Mac tests can use plain strings)

public struct PendingChange<Selection: Codable & Equatable>: Codable, Equatable {
    /// nil = the block is deleted when the change takes effect.
    public var plan: RulePlan?
    public var selection: Selection?
    public var effectiveAt: Date
    public init(plan: RulePlan?, selection: Selection?, effectiveAt: Date) {
        self.plan = plan; self.selection = selection; self.effectiveAt = effectiveAt
    }
}

public struct RuleRecord<Selection: Codable & Equatable>: Codable, Equatable, Identifiable {
    public var id: UUID
    public var plan: RulePlan
    public var selection: Selection
    public var pending: PendingChange<Selection>?
    public var createdAt: Date
    public init(id: UUID = UUID(), plan: RulePlan, selection: Selection, pending: PendingChange<Selection>? = nil,
                createdAt: Date = Date()) {
        self.id = id; self.plan = plan; self.selection = selection; self.pending = pending; self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, plan, selection, pending, createdAt }

    /// An unreadable queued change is dropped and the rule keeps running as it is (`DecodeReport` counts it, so
    /// the raw data can be kept); the rule itself must be readable.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        plan = try c.decode(RulePlan.self, forKey: .plan)
        selection = try c.decode(Selection.self, forKey: .selection)
        pending = (try? c.decodeIfPresent(PendingChange<Selection>.self, forKey: .pending)) ?? nil
        if pending == nil, c.contains(.pending), (try? c.decodeNil(forKey: .pending)) != true { DecodeReport.droppedPending += 1 }
        createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
    }
}

/// Counts what lenient decoding had to drop since the last reset (read by the app's state loader).
public enum DecodeReport {
    public static var droppedPending = 0
}

public enum Pending {
    /// Applies changes whose time has come. Returns the ids of rules that changed or were deleted.
    /// Nothing is applied while a lock-in runs (`frozenUntil` in the future): queued changes wait for it to end.
    @discardableResult
    public static func applyDue<S>(_ rules: inout [RuleRecord<S>], now: Date, frozenUntil: Date? = nil) -> Set<UUID> {
        if let f = frozenUntil, f > now { return [] }
        var changed = Set<UUID>()
        rules = rules.compactMap { rule in
            guard let p = rule.pending, p.effectiveAt <= now else { return rule }
            changed.insert(rule.id)
            guard let plan = p.plan else { return nil }
            var r = rule
            r.plan = plan
            if let s = p.selection { r.selection = s }
            r.pending = nil
            return r
        }
        return changed
    }
}

/// How many DeviceActivity monitors a set of rules needs (one per rule that is switched on).
public enum Capacity {
    public static func activities(for plans: [RulePlan]) -> Int { plans.filter(\.isOn).count }
    /// Rules that may be switched on, and rules that may exist at all (each keeps one store slot).
    public static var maxRules: Int { Limits.maxActivities - Limits.reservedActivities }
}

public enum Slots {
    /// Keeps existing rules' slots, frees deleted rules' slots, and gives new rules the lowest free slot.
    /// Rules beyond `count` get none (the app refuses to create that many).
    public static func assign(_ current: [String: Int], ruleIDs: [String], count: Int) -> [String: Int] {
        let ids = Set(ruleIDs)
        var out = current.filter { ids.contains($0.key) && (0..<count).contains($0.value) }
        var used = Set(out.values)
        for id in ruleIDs where out[id] == nil {
            guard let free = (0..<count).first(where: { !used.contains($0) }) else { break }
            out[id] = free
            used.insert(free)
        }
        return out
    }
}

public enum Coverage {
    /// Whether the switched-on schedules, together, leave at least `Limits.minimumFreeMinutes` free in every
    /// 24 hours. Otherwise blocks that include Arc Lock itself could keep it shut for good — no rule could ever
    /// be opened and changed again. Works on the week's wall-clock minutes; windows run past midnight.
    public static func leavesFreeTime(_ plans: [RulePlan]) -> Bool {
        let week = 7 * 24 * 60
        var covered = [Bool](repeating: false, count: week)
        for p in plans where p.isOn && p.kind == .schedule {
            let length = ScheduleMath.length(p.start, p.end)
            for day in p.days where (1...7).contains(day) {
                let first = (day - 1) * 24 * 60 + p.start.minutes
                for i in 0..<length { covered[(first + i) % week] = true }
            }
        }
        guard covered.contains(false) else { return false }
        guard covered.contains(true) else { return true }
        // runs around the week, starting at the first minute of a free run
        let start = (0..<week).first { !covered[$0] && covered[($0 + week - 1) % week] }!
        var runs: [(free: Bool, length: Int)] = []
        for i in 0..<week {
            let f = !covered[(start + i) % week]
            if let last = runs.last, last.free == f { runs[runs.count - 1].length += 1 } else { runs.append((f, 1)) }
        }
        // a free gap shorter than the minimum is no real chance to get in
        for i in runs.indices where runs[i].free && runs[i].length < Limits.minimumFreeMinutes { runs[i].free = false }
        var merged: [(free: Bool, length: Int)] = []
        for r in runs {
            if let last = merged.last, last.free == r.free { merged[merged.count - 1].length += r.length } else { merged.append(r) }
        }
        if merged.count > 1, merged[0].free == merged[merged.count - 1].free { merged[0].length += merged.removeLast().length }
        guard merged.contains(where: { $0.free }) else { return false }
        let longestBlocked = merged.filter { !$0.free }.map(\.length).max() ?? 0
        return longestBlocked <= 24 * 60 - Limits.minimumFreeMinutes
    }
}

public enum LimitMath {
    /// Usage events for a daily limit: each tenth of the limit (1…9) and the limit itself (10), in minutes after
    /// the monitor starts counting. `credit` = minutes already proven used today (after a mid-day edit): tenths
    /// already passed are left out and the rest come that much sooner. Every event is at least 1 minute.
    public static func thresholds(limit: Int, credit: Int = 0) -> [(tenth: Int, minutes: Int)] {
        var out: [(tenth: Int, minutes: Int)] = []
        for k in 1...9 {
            let remaining = limit * k / 10 - credit
            guard remaining >= 1, !out.contains(where: { $0.minutes == remaining }) else { continue }
            out.append((k, remaining))
        }
        out.append((10, max(1, limit - credit)))
        return out
    }

    /// The least usage (minutes) a mark level proves on a limit of `limit` minutes.
    public static func usedAtLeast(level: Int, limit: Int) -> Int { min(level, 10) * limit / 10 }

    /// The mark level `minutes` of use reaches on a limit of `limit` minutes (10 = used up).
    public static func level(forUsed minutes: Int, limit: Int) -> Int { min(10, max(0, minutes) * 10 / max(1, limit)) }
}

public enum Plausibility {
    /// Whether a usage threshold of `minutes` can really have been reached at `now` when counting began at
    /// `countingSince`: time used can never exceed time passed. Rejects the early callbacks iOS sometimes sends.
    public static func thresholdIsReal(minutes: Int, countingSince: Date, now: Date) -> Bool {
        let elapsed = now.timeIntervalSince(countingSince)
        return elapsed >= max(TimeInterval(minutes * 60) - 15, Limits.minimumEventDelay)
    }
}
