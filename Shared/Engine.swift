// Applying and lifting blocks. Each rule shields through its own ManagedSettingsStore (a slot from a fixed pool),
// so overlapping blocks never undo each other: iOS combines all stores and keeps the strictest value. While a store
// shields something it also stops app deletion and manual clock changes; those settings vanish with the block.
import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import UserNotifications

enum Shielding {
    static func apply(_ selection: FamilyActivitySelection, domains: [String], to name: ManagedSettingsStore.Name) {
        let store = ManagedSettingsStore(named: name)
        let apps = selection.applicationTokens, cats = selection.categoryTokens, webs = selection.webDomainTokens
        store.shield.applications = apps.isEmpty ? nil : apps
        store.shield.applicationCategories = cats.isEmpty ? nil : .specific(cats)
        store.shield.webDomains = webs.isEmpty ? nil : webs
        store.shield.webDomainCategories = cats.isEmpty ? nil : .specific(cats)
        let typed = Set(domains.map { WebDomain(domain: $0) })
        store.webContent.blockedByFilter = typed.isEmpty ? nil : .specific(typed)
        holdDevice(store)
    }

    /// No deleting apps (including Arc Lock) and no setting the clock by hand.
    static func holdDevice(_ store: ManagedSettingsStore) {
        store.application.denyAppRemoval = true
        store.dateAndTime.requireAutomaticDateAndTime = true
    }

    static func clear(_ name: ManagedSettingsStore.Name) {
        ManagedSettingsStore(named: name).clearAllSettings()
    }

    static func setLockIn(_ on: Bool) {
        let store = ManagedSettingsStore(named: Names.lockInStore)
        if on { holdDevice(store) } else { store.clearAllSettings() }
    }

    static func holdClock(_ on: Bool) {
        ManagedSettingsStore(named: Names.clockStore).dateAndTime.requireAutomaticDateAndTime = on ? true : nil
    }
}

/// What a rule's monitor was registered with. Compared with `==` (sets, not bytes), so an unchanged rule is never
/// re-registered — re-registering restarts a limit's count.
struct Registration: Codable, Equatable {
    var kind: RuleKind
    var start: TimeOfDay
    var end: TimeOfDay
    var limit: Int
    /// Event name → minutes after the count starts.
    var thresholds: [String: Int]
    /// The day a credit was applied (thresholds are only valid that day).
    var creditDay: Date?
    var selection: FamilyActivitySelection
}

enum Monitoring {
    struct Plan { let schedule: DeviceActivitySchedule; let events: [DeviceActivityEvent.Name: DeviceActivityEvent]; let registration: Registration }

    static func plan(for rule: Rule, now: Date = Date(), calendar: Calendar = .current) -> Plan {
        let p = rule.plan
        switch p.kind {
        case .schedule:
            let schedule = DeviceActivitySchedule(intervalStart: p.start.components, intervalEnd: p.end.components,
                                                  repeats: true, warningTime: DateComponents(minute: 5))
            return Plan(schedule: schedule, events: [:],
                        registration: Registration(kind: .schedule, start: p.start, end: p.end, limit: 0, thresholds: [:],
                                                   creditDay: nil, selection: rule.selection))
        case .limit:
            let credit = Credits.today(rule.id, now: now, calendar: calendar)
            let schedule = DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
                                                  intervalEnd: DateComponents(hour: 23, minute: 59), repeats: true,
                                                  warningTime: p.limitMinutes - credit >= 10 ? DateComponents(minute: 5) : nil)
            var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
            var thresholds: [String: Int] = [:]
            for t in LimitMath.thresholds(limit: p.limitMinutes, credit: credit) {
                let name = Names.event(tenth: t.tenth)
                events[name] = event(rule.selection, minutes: t.minutes)
                thresholds[name.rawValue] = t.minutes
            }
            return Plan(schedule: schedule, events: events,
                        registration: Registration(kind: .limit, start: TimeOfDay(0, 0), end: TimeOfDay(23, 59), limit: p.limitMinutes,
                                                   thresholds: thresholds, creditDay: credit > 0 ? calendar.startOfDay(for: now) : nil,
                                                   selection: rule.selection))
        }
    }

    private static func event(_ s: FamilyActivitySelection, minutes: Int) -> DeviceActivityEvent {
        // The count starts when the monitor is registered (and at every midnight after). With past activity counted,
        // iOS fires at once for use before the limit existed — indistinguishable from its known early-fire bug.
        DeviceActivityEvent(applications: s.applicationTokens, categories: s.categoryTokens, webDomains: s.webDomainTokens,
                            threshold: DateComponents(minute: minutes), includesPastActivity: false)
    }

    private static func regKey(_ id: UUID) -> String { "registration.\(id.uuidString)" }
    private static func regAtKey(_ id: UUID) -> String { "regat.\(id.uuidString)" }

    static func registration(_ id: UUID) -> Registration? {
        guard let d = AppGroup.defaults.data(forKey: regKey(id)) else { return nil }
        return try? JSONDecoder().decode(Registration.self, from: d)
    }
    /// When a rule's monitor was last (re)registered — today's count starts at the later of this and midnight.
    static func registeredAt(_ id: UUID) -> Date? { AppGroup.defaults.object(forKey: regAtKey(id)) as? Date }

    static func countingSince(_ id: UUID, now: Date = Date(), calendar: Calendar = .current) -> Date {
        max(calendar.startOfDay(for: now), registeredAt(id) ?? .distantPast)
    }

    static func forget(_ id: UUID) {
        AppGroup.defaults.removeObject(forKey: regKey(id))
        AppGroup.defaults.removeObject(forKey: regAtKey(id))
    }

    /// Starts, restarts or stops DeviceActivity monitors to match the state; `force` restarts those rules even if
    /// unchanged. Returns problems worth showing.
    @discardableResult
    static func sync(_ state: ArcState, now: Date = Date(), force: Set<UUID> = []) -> [Error] {
        let center = DeviceActivityCenter()
        var errors: [Error] = []
        var wanted: [DeviceActivityName: (Rule, Plan)] = [:]
        for rule in state.rules where rule.plan.isOn { wanted[Names.activity(rule.id)] = (rule, plan(for: rule, now: now)) }

        let have = Set(center.activities)
        let stale = have.filter { $0 != Names.session && $0 != Names.daily && wanted[$0] == nil }
        if !stale.isEmpty { center.stopMonitoring(Array(stale)) }

        for (name, (rule, p)) in wanted {
            if have.contains(name), !force.contains(rule.id), registration(rule.id) == p.registration { continue }
            do {
                try center.startMonitoring(name, during: p.schedule, events: p.events)
                if let d = try? JSONEncoder().encode(p.registration) { AppGroup.defaults.set(d, forKey: regKey(rule.id)) }
                AppGroup.defaults.set(now, forKey: regAtKey(rule.id))
            } catch { errors.append(error) }
        }

        // Housekeeping at midnight: pending changes, lock-in and Block-now endings even if the app stays closed.
        if !have.contains(Names.daily) {
            let daily = DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
                                               intervalEnd: DateComponents(hour: 23, minute: 59), repeats: true)
            do { try center.startMonitoring(Names.daily, during: daily) } catch { errors.append(error) }
        }
        return errors
    }

    /// After iOS reported a limit too early (and so won't report it again today), restart the count with what
    /// today's marks prove was used. At most 3 times a day, so a device that misfires every time can't loop.
    static func rearm(_ rule: Rule, state: ArcState, now: Date = Date(), calendar: Calendar = .current) {
        let key = "rearm.\(rule.id.uuidString)"
        let today = calendar.startOfDay(for: now)
        var count = 0
        if let d = AppGroup.defaults.object(forKey: key + ".day") as? Date, calendar.isDate(d, inSameDayAs: now) {
            count = AppGroup.defaults.integer(forKey: key)
        }
        guard count < 3 else { return }
        AppGroup.defaults.set(today, forKey: key + ".day")
        AppGroup.defaults.set(count + 1, forKey: key)
        let used = LimitMath.usedAtLeast(level: Marks.level(rule.id, now: now, calendar: calendar), limit: rule.plan.limitMinutes)
        Credits.set(rule.id, minutes: max(used, Credits.today(rule.id, now: now, calendar: calendar)), now: now, calendar: calendar)
        sync(state, now: now, force: [rule.id])
    }

    /// One-off monitor whose end lifts a Block-now session even if the app is never opened again. The start is a
    /// minute in the past and only clock components are used: a start of exactly "now" can slip to tomorrow.
    static func startSession(_ s: FocusSession, calendar: Calendar = .current) throws {
        let comps: Set<Calendar.Component> = [.hour, .minute, .second]
        let schedule = DeviceActivitySchedule(intervalStart: calendar.dateComponents(comps, from: s.startedAt.addingTimeInterval(-60)),
                                              intervalEnd: calendar.dateComponents(comps, from: s.endsAt), repeats: false)
        let center = DeviceActivityCenter()
        center.stopMonitoring([Names.session])
        try center.startMonitoring(Names.session, during: schedule)
    }
}

enum Engine {
    /// A block whose end is this close counts as over, and one whose start is this close counts as started, so a
    /// callback that comes a little early or late never leaves a shield behind (or misses a start).
    static let edge: TimeInterval = 60

    /// Makes the shields match the rules at `now`. Idempotent; the app calls it whenever it opens, the monitor
    /// extension after every callback. The rules are the source of truth, so a missed callback heals at the next one.
    static func reconcile(_ state: ArcState, now: Date = Date(), calendar: Calendar = .current, skip: Set<UUID> = []) {
        for slot in 0..<Names.slotCount {
            let name = Names.store(slot: slot)
            guard let rule = state.rules.first(where: { state.slot(of: $0.id) == slot }) else {
                Shielding.clear(name)
                continue
            }
            if skip.contains(rule.id) { continue }
            if isBlocking(rule, now: now, calendar: calendar) {
                Shielding.apply(rule.selection, domains: rule.plan.domains, to: name)
            } else {
                Shielding.clear(name)
            }
        }
        let sessionOn = state.session.map { $0.endsAt.timeIntervalSince(now) > edge && $0.startedAt <= now.addingTimeInterval(edge) } ?? false
        if let s = state.session, sessionOn {
            Shielding.apply(s.selection, domains: s.domains, to: Names.sessionStore)
        } else {
            Shielding.clear(Names.sessionStore)
        }
        let lockIn = (state.lockInUntil?.timeIntervalSince(now) ?? 0) > edge
        Shielding.setLockIn(lockIn)
        Shielding.holdClock(lockIn || sessionOn || state.rules.contains { $0.plan.isOn || $0.pending != nil })
    }

    /// Whether a rule should shield at `now` (see `edge`).
    static func isBlocking(_ rule: Rule, now: Date, calendar: Calendar = .current) -> Bool {
        let status = Status.of(rule.plan, now: now, reachedAt: Marks.reachedAt(rule.id), calendar: calendar)
        if let until = status.blockingUntil { return until.timeIntervalSince(now) > edge }
        if case .waiting(let next?) = status, next.timeIntervalSince(now) <= edge { return true }
        return false
    }

    static func store(for id: UUID, in state: ArcState) -> ManagedSettingsStore.Name? {
        state.slot(of: id).map { Names.store(slot: $0) }
    }

    /// Ends an expired lock-in and Block-now session, then applies pending (looser) changes whose time has come —
    /// never during a lock-in. Writes only when something changed (the app may be writing too).
    @discardableResult
    static func housekeep(now: Date = Date()) -> (ArcState, Bool) {
        var st = StateStore.load()
        func tidy(_ s: inout ArcState) -> Set<UUID> {
            if let l = s.lockInUntil, l <= now { s.lockInUntil = nil }
            if let sess = s.session, sess.endsAt <= now { s.session = nil }
            return Pending.applyDue(&s.rules, now: now, frozenUntil: s.lockInUntil)
        }
        var probe = st
        let due = tidy(&probe)
        guard !due.isEmpty || probe.session != st.session || probe.lockInUntil != st.lockInUntil else { return (st, false) }
        st = StateStore.update { fresh in
            let ids = tidy(&fresh)
            for id in ids {
                // the change restarts the count; old marks or credit would mean a different limit (e.g. after a
                // time-zone change applied it mid-day) — start clean rather than risk a false lock
                Marks.clear(id)
                Credits.clear(id)
                guard !fresh.rules.contains(where: { $0.id == id }) else { continue }
                if let slot = fresh.slot(of: id) { Shielding.clear(Names.store(slot: slot)) }
                Restarts.clear(id)
                Monitoring.forget(id)
            }
            fresh.assignSlots()
        }
        return (st, true)
    }

    /// Whether `now` falls on a day this limit counts.
    static func counts(_ rule: Rule, now: Date, calendar: Calendar = .current) -> Bool {
        rule.plan.isOn && rule.plan.kind == .limit && rule.plan.days.contains(calendar.component(.weekday, from: now))
    }
}

enum Notify {
    static func post(id: String, title: String, body: String) {
        guard StateStore.load().headsUp else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }
}
