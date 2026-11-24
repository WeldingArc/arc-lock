// Applying and lifting blocks. Each rule shields through its own ManagedSettingsStore (a slot from a fixed pool),
// so overlapping blocks never undo each other: iOS combines all stores and keeps the strictest value. While a store
// shields something it also stops app deletion and manual clock changes; those settings vanish with the block.
// During an emergency relief (Relief) every store's shields stay off, but those holds stay as they are.
import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import UserNotifications

enum Shielding {
    /// `hold` = a strict block: also stop app deletion and manual clock changes while it shields. Every path that
    /// shields comes through here, so during an emergency relief (Relief, at `now`) none does: the apps and websites
    /// stay open, while a strict block still stops app deletion and manual clock changes.
    static func apply(_ selection: FamilyActivitySelection, domains: [String], to name: ManagedSettingsStore.Name, hold: Bool = true,
                      now: Date = Date()) {
        let store = ManagedSettingsStore(named: name)
        if Relief.isActive(now: now) {
            clearShields(store)
        } else {
            let apps = selection.applicationTokens, cats = selection.categoryTokens, webs = selection.webDomainTokens
            store.shield.applications = apps.isEmpty ? nil : apps
            store.shield.applicationCategories = cats.isEmpty ? nil : .specific(cats)
            store.shield.webDomains = webs.isEmpty ? nil : webs
            store.shield.webDomainCategories = cats.isEmpty ? nil : .specific(cats)
            let typed = Set(domains.map { WebDomain(domain: $0) })
            store.webContent.blockedByFilter = typed.isEmpty ? nil : .specific(typed)
        }
        if hold {
            holdDevice(store)
        } else {
            store.application.denyAppRemoval = nil
            store.dateAndTime.requireAutomaticDateAndTime = nil
        }
    }

    /// Nothing shielded in this store (apps, categories, picked and typed websites); its holds stay as they are.
    static func clearShields(_ store: ManagedSettingsStore) {
        store.shield.applications = nil
        store.shield.applicationCategories = nil
        store.shield.webDomains = nil
        store.shield.webDomainCategories = nil
        store.webContent.blockedByFilter = nil
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

    static func guardDeletion(_ on: Bool) {
        ManagedSettingsStore(named: Names.guardStore).application.denyAppRemoval = on ? true : nil
    }

    static func holdClock(_ on: Bool) {
        ManagedSettingsStore(named: Names.clockStore).dateAndTime.requireAutomaticDateAndTime = on ? true : nil
    }
}

/// What a rule's monitor was registered with. Compared field by field (sets, not bytes), so an unchanged rule is never
/// registered again — that would restart a time-out's count (a daily limit then counts its whole period again).
struct Registration: Codable, Equatable {
    var kind: RuleKind
    var start: TimeOfDay
    var end: TimeOfDay
    var limit: Int
    /// Event name → minutes after the count starts.
    var thresholds: [String: Int]
    /// With `credit`: the start of the period the credit belongs to (its thresholds hold only then). Versions before
    /// 1.1.1 set it without `credit` (a daily limit's carried-over use); such a registration is registered again.
    var creditDay: Date?
    var selection: FamilyActivitySelection
    /// true = the events count use from before the monitor was registered (daily limits: the whole period). nil in
    /// registrations saved before 1.1.1, which count from the registration only.
    var pastActivity: Bool? = nil
    /// Minutes of use already proven when this count began (a time-out, or a limit counting from registration,
    /// registered again mid-way — Monitoring.credit): the thresholds are what's left. nil = none.
    var credit: Int? = nil

    /// Whether this registration serves `wanted`: the same rule, thresholds and apps, counted the same way. A daily limit
    /// that should count its whole day (`wanted.pastActivity` true) but was registered to count from registration — by
    /// 1.1.0 or earlier (nil), or for the rest of the day its reset time changed (false, FreshCounts) — is registered
    /// again: iOS can stop reporting such a count altogether (Josh's iPhone, 2026-11-23: a 45-min limit from the day
    /// before, Instagram well past it, not one report). Registered anew it counts the whole day, so a limit already
    /// used up locks at once; the saved registration then counts the whole day, so this happens once.
    /// A registration with a credit (counting on from use already proven) serves the plain one for the rest of the
    /// period it was given in: its thresholds are the rest of the same limit. After the block's reset it doesn't.
    func serves(_ wanted: Registration, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        if pastActivity != true && wanted.pastActivity == true { return false }
        var mine = self
        mine.pastActivity = wanted.pastActivity
        // a schedule's monitor has no events: the apps it blocks don't matter to it (reconcile shields them). Not
        // registering it again for new apps keeps iOS from ending its interval early (ActivityMonitor.intervalDidEnd).
        if kind == .schedule { mine.selection = wanted.selection }
        if let credit = mine.credit, credit > 0 {
            guard Counting.creditHolds(creditDay: mine.creditDay, resetAt: start, now: now, calendar: calendar) else { return false }
            mine.credit = wanted.credit
            mine.creditDay = wanted.creditDay
            mine.thresholds = wanted.thresholds
        }
        // A time-out registered by 1.1.1 or earlier has one event, at the break, and no tenths: the same break, so it
        // keeps serving until that break registers it again (Monitoring.finishBreaks). Registering it anew right after
        // the update would start its stretch over, and its break would be read as one from another version — skipped.
        if kind == .timeout, mine.credit == nil, mine.thresholds == [Names.limitEvent.rawValue: limit],
           wanted.thresholds[Names.limitEvent.rawValue] == limit {
            mine.thresholds = wanted.thresholds
        }
        return mine == wanted
    }
}

enum Monitoring {
    struct Plan { let schedule: DeviceActivitySchedule; let events: [DeviceActivityEvent.Name: DeviceActivityEvent]; let registration: Registration }

    /// `credit` = minutes of use already proven in the current period (a time-out: its current stretch), for a count
    /// that starts at registration: the thresholds are then what's left (see `credit(for:)`). A daily limit that
    /// counts its whole day ignores it — iOS counts the earlier use itself.
    static func plan(for rule: Rule, now: Date = Date(), credit: Int = 0, calendar: Calendar = .current) -> Plan {
        let p = rule.plan
        let periodStart = Period.start(containing: now, resetAt: p.resetAt, calendar: calendar)
        switch p.kind {
        case .schedule:
            let schedule = DeviceActivitySchedule(intervalStart: p.start.components, intervalEnd: p.end.components,
                                                  repeats: true, warningTime: DateComponents(minute: 5))
            return Plan(schedule: schedule, events: [:],
                        registration: Registration(kind: .schedule, start: p.start, end: p.end, limit: 0, thresholds: [:],
                                                   creditDay: nil, selection: rule.selection))
        case .limit:
            // the block's own day: from its reset time to the minute before the next one (00:00–23:59 by default).
            // Its events count the whole day, use from before the block was saved or changed included: a limit set
            // (or made stricter) after its time is used up locks at once, not only after its next reset. Right after
            // its reset time changed (FreshCounts), or with a reset off the hour, it counts from registration.
            let past = countsEarlierUse(p, id: rule.id, now: now)
            let carried = past ? 0 : max(0, credit)
            let schedule = DeviceActivitySchedule(intervalStart: p.resetAt.components, intervalEnd: p.resetAt.minuteBefore.components,
                                                  repeats: true,
                                                  warningTime: p.limitMinutes >= 10 ? DateComponents(minute: 5) : nil)
            var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
            var thresholds: [String: Int] = [:]
            for t in LimitMath.thresholds(limit: p.limitMinutes, credit: carried) {
                let name = Names.event(tenth: t.tenth)
                events[name] = event(rule.selection, minutes: t.minutes, past: past)
                thresholds[name.rawValue] = t.minutes
            }
            return Plan(schedule: schedule, events: events,
                        registration: Registration(kind: .limit, start: p.resetAt, end: p.resetAt.minuteBefore, limit: p.limitMinutes,
                                                   thresholds: thresholds, creditDay: carried > 0 ? periodStart : nil,
                                                   selection: rule.selection, pastActivity: past,
                                                   credit: carried > 0 ? carried : nil))
        case .place:
            // never registered (sync skips place blocks: iOS reports places to the app, not to a monitor)
            return Plan(schedule: DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
                                                         intervalEnd: DateComponents(hour: 23, minute: 59), repeats: true),
                        events: [:],
                        registration: Registration(kind: .place, start: .midnight, end: TimeOfDay(23, 59), limit: 0, thresholds: [:],
                                                   creditDay: nil, selection: rule.selection))
        case .timeout:
            // the use allowed before a break, counted from registration (registered again after each break), in tenths:
            // "limit" starts the break, p1…p9 mark the way, so a time-out registered again mid-stretch (an app added,
            // fresh app tokens) counts on from what's used instead of starting a fresh stretch
            let carried = max(0, credit)
            let schedule = DeviceActivitySchedule(intervalStart: p.resetAt.components, intervalEnd: p.resetAt.minuteBefore.components,
                                                  repeats: true,
                                                  warningTime: p.limitMinutes >= 3 ? DateComponents(minute: 1) : nil)
            var events: [DeviceActivityEvent.Name: DeviceActivityEvent] = [:]
            var thresholds: [String: Int] = [:]
            for t in LimitMath.thresholds(limit: p.limitMinutes, credit: carried) {
                let name = Names.event(tenth: t.tenth)
                events[name] = event(rule.selection, minutes: t.minutes, past: false)
                thresholds[name.rawValue] = t.minutes
            }
            return Plan(schedule: schedule, events: events,
                        registration: Registration(kind: .timeout, start: p.resetAt, end: p.resetAt.minuteBefore, limit: p.limitMinutes,
                                                   thresholds: thresholds, creditDay: carried > 0 ? periodStart : nil,
                                                   selection: rule.selection, credit: carried > 0 ? carried : nil))
        }
    }

    /// Use (minutes) already proven, by its marks, in a block's current count when that count starts at registration:
    /// a time-out's stretch of use (its marks are cleared when a break starts and ends), or a daily limit counting from
    /// registration (right after its reset time changed, or off the hour). Registering it again mid-way — an edit,
    /// fresh app tokens, a re-arm — then counts on from there instead of handing out that time again. Zero for a
    /// limit that counts its whole day: iOS counts the earlier use itself.
    static func credit(for rule: Rule, now: Date = Date(), calendar: Calendar = .current) -> Int {
        let p = rule.plan
        guard p.kind.countsUse, !countsEarlierUse(p, id: rule.id, now: now) else { return 0 }
        let level = Marks.level(rule.id, period: Period.start(containing: now, resetAt: p.resetAt, calendar: calendar))
        return LimitMath.usedAtLeast(level: level, limit: p.limitMinutes)
    }

    /// Whether a daily limit (with this plan) registered now counts its whole period, earlier use included (Core
    /// `Counting.includesPast`). When it doesn't, a restart of its count would hand out time already used.
    static func countsEarlierUse(_ plan: RulePlan, id: UUID, now: Date = Date()) -> Bool {
        plan.kind == .limit && Counting.includesPast(resetAt: plan.resetAt, freshUntil: FreshCounts.until(id), now: now)
    }

    /// `past` = count the use since the interval began, from before registration too (daily limits). Without it the
    /// count starts at registration (and at every interval start after): a time-out's stretch of use, which starts
    /// over after each break.
    private static func event(_ s: FamilyActivitySelection, minutes: Int, past: Bool) -> DeviceActivityEvent {
        DeviceActivityEvent(applications: s.applicationTokens, categories: s.categoryTokens, webDomains: s.webDomainTokens,
                            threshold: DateComponents(minute: minutes), includesPastActivity: past)
    }

    private static func regKey(_ id: UUID) -> String { "registration.\(id.uuidString)" }
    private static func regAtKey(_ id: UUID) -> String { "regat.\(id.uuidString)" }

    static func registration(_ id: UUID) -> Registration? {
        guard let d = AppGroup.defaults.data(forKey: regKey(id)) else { return nil }
        return try? JSONDecoder().decode(Registration.self, from: d)
    }
    /// When a rule's monitor was last (re)registered.
    static func registeredAt(_ id: UUID) -> Date? { AppGroup.defaults.object(forKey: regAtKey(id)) as? Date }

    /// When the count iOS is keeping for a block began: a daily limit's period start (its use from before it was
    /// saved counts too); a time-out's last reset, or a later (re-)registration. Follows what the monitor was really
    /// registered with, so a limit still registered by an older version counts from its registration until then.
    static func countingSince(_ id: UUID, resetAt: TimeOfDay, now: Date = Date(), calendar: Calendar = .current) -> Date {
        Counting.since(periodStart: Period.start(containing: now, resetAt: resetAt, calendar: calendar),
                       registeredAt: registeredAt(id), includesPast: registration(id)?.pastActivity == true, calendar: calendar)
    }

    static func forget(_ id: UUID) {
        AppGroup.defaults.removeObject(forKey: regKey(id))
        AppGroup.defaults.removeObject(forKey: regAtKey(id))
    }

    /// Starts, restarts or stops DeviceActivity monitors to match the state; `force` restarts those rules even if
    /// unchanged. Returns problems worth showing.
    @discardableResult
    static func sync(_ given: ArcState, now: Date = Date(), force: Set<UUID> = []) -> [Error] {
        // another process may have saved newer rules since `given` was read (the app while a monitor callback runs, or
        // the other way round): work from the freshest copy, so a block just added isn't stopped again
        let latest = StateStore.load()
        let state = latest.isSetUp ? latest : given
        // a state that isn't set up may be one that couldn't be read (ArcState.isSetUp): every monitor would look
        // unwanted and be stopped
        guard state.isSetUp else { return [] }
        let center = DeviceActivityCenter()
        var errors: [Error] = []
        var wanted: [DeviceActivityName: (Rule, Plan)] = [:]
        for rule in state.rules where rule.plan.isOn && rule.plan.kind != .place {
            wanted[Names.activity(rule.id)] = (rule, plan(for: rule, now: now))
        }

        let have = Set(center.activities)
        // a running break keeps its own monitor (its end lifts the break); anything else not wanted goes
        let liveBreaks = Set(state.rules.filter { $0.plan.isOn && $0.plan.kind == .timeout && (Breaks.until($0.id) ?? .distantPast) > now }
            .map { Names.breakActivity($0.id) })
        // a running place block keeps its one-off end monitor (and gets one if it's missing)
        let runningPlaces = state.rules.filter {
            $0.plan.isOn && $0.plan.kind == .place && PlaceRules.isRunning(PlaceVisits.get($0.id), now: now)
        }
        let livePlaces = Set(runningPlaces.map { Names.placeActivity($0.id) })
        // a running emergency relief keeps its one-off end monitor: its end brings the shields back
        let reliefLive = (Relief.until ?? .distantPast) > now
        // stale monitors go first: at iOS's 20-monitor cap a missing one couldn't start before they're gone
        let stale = have.filter { $0 != Names.session && $0 != Names.daily && wanted[$0] == nil && !liveBreaks.contains($0)
            && !livePlaces.contains($0) && !(reliefLive && $0 == Names.relief) && !Diag.probeNames.contains($0) }
        if !stale.isEmpty { center.stopMonitoring(Array(stale)) }
        for rule in runningPlaces where !have.contains(Names.placeActivity(rule.id)) {
            let visit = PlaceVisits.get(rule.id)
            if let started = visit?.started, let latest = PlaceRules.latestEnd(visit, now: now) {
                startPlaceEnd(rule.id, from: started, to: latest)
            }
        }

        for (name, (rule, wantedPlan)) in wanted {
            if have.contains(name), !force.contains(rule.id), registration(rule.id)?.serves(wantedPlan.registration, now: now) == true { continue }
            // a count that starts at registration keeps the use its marks prove (credit(for:))
            let given = credit(for: rule, now: now)
            let p = given > 0 ? plan(for: rule, now: now, credit: given) : wantedPlan
            do {
                try center.startMonitoring(name, during: p.schedule, events: p.events)
                if let d = try? JSONEncoder().encode(p.registration) { AppGroup.defaults.set(d, forKey: regKey(rule.id)) }
                AppGroup.defaults.set(now, forKey: regAtKey(rule.id))
                Diag.log("registered \(name.rawValue) (\(p.events.count) events\(given > 0 ? ", \(given) min used" : ""))")
            } catch {
                Diag.log("register \(name.rawValue) FAILED: \(error)")
                errors.append(error)
            }
        }

        // Housekeeping at midnight too (a lock-in ends then), even if the app stays closed. Each block's own reset
        // is its monitor's interval start, so pending changes land on time without this.
        if !have.contains(Names.daily) {
            let daily = DeviceActivitySchedule(intervalStart: DateComponents(hour: 0, minute: 0),
                                               intervalEnd: DateComponents(hour: 23, minute: 59), repeats: true)
            do { try center.startMonitoring(Names.daily, during: daily) } catch { errors.append(error) }
        }
        return errors
    }

    /// After iOS reported a limit too early (and so won't report it again this period), register its monitor again
    /// so iOS counts afresh: a daily limit its whole period again, earlier use included; a time-out from now on.
    /// At most 3 times a period, so a device that misfires every time can't loop.
    static func rearm(_ rule: Rule, state: ArcState, now: Date = Date(), calendar: Calendar = .current) {
        let key = rearmKey(rule.id)
        let today = Period.start(containing: now, resetAt: rule.plan.resetAt, calendar: calendar)
        var count = 0
        if let d = AppGroup.defaults.object(forKey: key + ".day") as? Date, abs(d.timeIntervalSince(today)) < 1 {
            count = AppGroup.defaults.integer(forKey: key)
        }
        guard count < 3 else { return }
        AppGroup.defaults.set(today, forKey: key + ".day")
        AppGroup.defaults.set(count + 1, forKey: key)
        sync(state, now: now, force: [rule.id])
    }

    private static func rearmKey(_ id: UUID) -> String { "rearm.\(id.uuidString)" }
    /// A time-out re-registers after every break, so each stretch of use gets its own budget of 3 re-arms.
    static func resetRearms(_ id: UUID) {
        AppGroup.defaults.removeObject(forKey: rearmKey(id))
        AppGroup.defaults.removeObject(forKey: rearmKey(id) + ".day")
    }

    /// Starts a time-out's break: shields until `now + breakMinutes`, with a one-off monitor whose end lifts the break.
    /// iOS wants monitors of at least 15 minutes, so a shorter break's monitor starts in the past.
    static func startBreak(_ rule: Rule, now: Date = Date(), calendar: Calendar = .current) {
        let end = now.addingTimeInterval(TimeInterval(rule.plan.breakMinutes * 60))
        Breaks.set(rule.id, until: end)
        Stops.clear(rule.id)          // a stop belonged to an earlier break; this one blocks
        Marks.clear(rule.id)          // this stretch of use is over; the next one starts after the break
        let start = min(now.addingTimeInterval(-60), end.addingTimeInterval(-16 * 60))
        let comps: Set<Calendar.Component> = [.hour, .minute, .second]
        let schedule = DeviceActivitySchedule(intervalStart: calendar.dateComponents(comps, from: start),
                                              intervalEnd: calendar.dateComponents(comps, from: end), repeats: false)
        let center = DeviceActivityCenter()
        center.stopMonitoring([Names.breakActivity(rule.id)])
        do {
            try center.startMonitoring(Names.breakActivity(rule.id), during: schedule)
            Diag.log("break monitor until \(end)")
        } catch {
            Diag.log("break monitor FAILED: \(error)")
        }
    }

    /// Ends breaks whose time is up and restarts their count from now, so the next break comes after the full use
    /// time again. Safe to call from any callback or when the app opens (a missed break-end heals here). `slack`
    /// also ends breaks that are due within that time (a break monitor's end can come a moment early); the count
    /// still restarts at the real `now`, which the next threshold's plausibility check measures from.
    @discardableResult
    static func finishBreaks(_ state: ArcState, now: Date = Date(), slack: TimeInterval = 0) -> Bool {
        let due = now.addingTimeInterval(slack)
        let done = state.rules.filter { $0.plan.kind == .timeout && (Breaks.until($0.id).map { $0 <= due } ?? false) }
        guard !done.isEmpty else { return false }
        for r in done {
            Breaks.clear(r.id)
            Marks.clear(r.id)         // a new stretch of use: its count starts at zero (Monitoring.credit)
            resetRearms(r.id)
            Diag.log("break over for \(r.id.uuidString.prefix(8))")
        }
        DeviceActivityCenter().stopMonitoring(done.map { Names.breakActivity($0.id) })
        sync(state, now: now, force: Set(done.filter(\.plan.isOn).map(\.id)))
        return true
    }

    /// One-off monitor whose end lifts a running place block at its latest end — its set time, or the 12-hour safety
    /// end of one that ends when you leave — even if Arc Lock stays closed (like a Block-now session). Leaving itself
    /// needs none: iOS wakes the app for that.
    static func startPlaceEnd(_ id: UUID, from start: Date, to end: Date, calendar: Calendar = .current) {
        let comps: Set<Calendar.Component> = [.hour, .minute, .second]
        // iOS wants at least 15 minutes; a block set to a time lasts that long, so starting a minute early is enough
        let begin = min(start.addingTimeInterval(-60), end.addingTimeInterval(-16 * 60))
        let schedule = DeviceActivitySchedule(intervalStart: calendar.dateComponents(comps, from: begin),
                                              intervalEnd: calendar.dateComponents(comps, from: end), repeats: false)
        let center = DeviceActivityCenter()
        center.stopMonitoring([Names.placeActivity(id)])
        do {
            try center.startMonitoring(Names.placeActivity(id), during: schedule)
        } catch {
            Diag.log("place monitor FAILED: \(error)")
        }
    }

    static func stopPlaceEnd(_ id: UUID) {
        DeviceActivityCenter().stopMonitoring([Names.placeActivity(id)])
    }

    /// One-off monitor whose end brings the shields back after an emergency relief, even if Arc Lock stays closed
    /// (ActivityMonitor.intervalDidEnd). Like a Block-now session's, it starts a minute in the past, with clock
    /// components only. Throws when iOS won't watch one more activity (all 20 in use): the relief can't start then.
    static func startRelief(from start: Date, until end: Date, calendar: Calendar = .current) throws {
        let comps: Set<Calendar.Component> = [.hour, .minute, .second]
        let begin = min(start.addingTimeInterval(-60), end.addingTimeInterval(-16 * 60))
        let schedule = DeviceActivitySchedule(intervalStart: calendar.dateComponents(comps, from: begin),
                                              intervalEnd: calendar.dateComponents(comps, from: end), repeats: false)
        let center = DeviceActivityCenter()
        center.stopMonitoring([Names.relief])
        try center.startMonitoring(Names.relief, during: schedule)
    }

    /// The relief's end came while Arc Lock's data couldn't be read (before the first unlock after a restart), so its
    /// shields couldn't come back yet: look again in 15 minutes, and again after that, until they can.
    static func retryReliefEnd(now: Date = Date(), calendar: Calendar = .current) {
        let comps: Set<Calendar.Component> = [.hour, .minute, .second]
        let schedule = DeviceActivitySchedule(intervalStart: calendar.dateComponents(comps, from: now.addingTimeInterval(-60)),
                                              intervalEnd: calendar.dateComponents(comps, from: now.addingTimeInterval(15 * 60)),
                                              repeats: false)
        let center = DeviceActivityCenter()
        center.stopMonitoring([Names.relief])
        try? center.startMonitoring(Names.relief, during: schedule)
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
    static func reconcile(_ given: ArcState, now: Date = Date(), calendar: Calendar = .current, skip: Set<UUID> = []) {
        // another process may have saved newer rules since `given` was read: act on the freshest copy, so a block just
        // added isn't lifted and the apps of one just deleted aren't shielded in its old slot
        let latest = StateStore.load()
        let state = latest.isSetUp ? latest : given
        // a state that isn't set up may be one that couldn't be read (ArcState.isSetUp): clearing every store for it
        // would lift every block, the lock-in and deletion protection. Everything stays as it is until a real read.
        guard state.isSetUp else { return }
        for slot in 0..<Names.slotCount {
            let name = Names.store(slot: slot)
            guard let rule = state.rules.first(where: { state.slot(of: $0.id) == slot }) else {
                Shielding.clear(name)
                continue
            }
            if skip.contains(rule.id) { continue }
            if isBlocking(rule, now: now, calendar: calendar) {
                Shielding.apply(rule.selection, domains: rule.plan.domains, to: name, hold: state.isStrict(rule, now: now), now: now)
            } else {
                Shielding.clear(name)
            }
        }
        let sessionOn = state.session.map { $0.endsAt.timeIntervalSince(now) > edge && $0.startedAt <= now.addingTimeInterval(edge) } ?? false
        if let s = state.session, sessionOn {
            Shielding.apply(s.selection, domains: s.domains, to: Names.sessionStore, hold: state.isStrict(s, now: now), now: now)
        } else {
            Shielding.clear(Names.sessionStore)
        }
        let lockIn = (state.lockInUntil?.timeIntervalSince(now) ?? 0) > edge
        Shielding.setLockIn(lockIn)
        let strictSession = sessionOn && (state.session.map { state.isStrict($0, now: now) } ?? false)
        Shielding.holdClock(lockIn || strictSession
                            || state.rules.contains { ($0.plan.isOn && state.isStrict($0, now: now)) || $0.pending != nil })
        Shielding.guardDeletion(state.onboarded && state.deletionProtection)
    }

    /// A rule's status at `now`, from what was recorded (use, breaks, stops, a place block's visit).
    static func status(_ rule: Rule, now: Date, calendar: Calendar = .current) -> RuleStatus {
        Status.of(rule.plan, now: now, reachedAt: Marks.reachedAt(rule.id), breakUntil: Breaks.until(rule.id),
                  stoppedUntil: Stops.until(rule.id), visit: rule.plan.kind == .place ? PlaceVisits.get(rule.id) : nil,
                  calendar: calendar)
    }

    /// Whether a rule should shield at `now` (see `edge`).
    static func isBlocking(_ rule: Rule, now: Date, calendar: Calendar = .current) -> Bool {
        let status = Engine.status(rule, now: now, calendar: calendar)
        // A break can be as short as a minute, so no edge here: `finishBreaks` ends it (allowing for an early callback).
        if case .onBreak(let until) = status { return until > now }
        if case .atPlace(let latest) = status { return latest.timeIntervalSince(now) > edge }   // until you leave, or the safety end
        if let until = status.blockingUntil { return until.timeIntervalSince(now) > edge }
        if case .waiting(let next?) = status, next.timeIntervalSince(now) <= edge { return true }
        return false
    }

    /// Whether any block or Block now holds something at `now`: what an emergency relief lifts.
    static func anythingBlocking(_ state: ArcState, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        state.rules.contains { isBlocking($0, now: now, calendar: calendar) }
            || (state.session.map { $0.endsAt.timeIntervalSince(now) > edge && $0.startedAt <= now.addingTimeInterval(edge) } ?? false)
    }

    static func store(for id: UUID, in state: ArcState) -> ManagedSettingsStore.Name? {
        state.slot(of: id).map { Names.store(slot: $0) }
    }

    /// Ends an expired lock-in and Block-now session, then applies pending (looser) changes whose time has come —
    /// never during a lock-in. Writes only when something changed (the app may be writing too).
    @discardableResult
    static func housekeep(now: Date = Date()) -> (ArcState, Bool) {
        var st = StateStore.load()
        // nothing to tidy in a state that isn't set up — and one that couldn't be read must not be written back
        guard st.isSetUp else { return (st, false) }
        func tidy(_ s: inout ArcState) -> (Set<UUID>, Bool) {
            // a lock-in holds queued changes; a limit's or time-out's change still lands on its own reset (checked
            // before an ended lock-in is cleared, so the moment it ends can't apply one mid-period)
            let moved = Pending.holdForLockIn(&s.rules, lockInUntil: s.lockInUntil, calendar: .autoupdatingCurrent)
            if let l = s.lockInUntil, l <= now { s.lockInUntil = nil }
            // the time the strict blocks needed (their own resets or ends); a callback a moment early still counts
            if let off = s.deletionProtectionOffAt, off.timeIntervalSince(now) <= edge, (s.lockInUntil ?? .distantPast) <= now {
                s.deletionProtection = false
                s.deletionProtectionOffAt = nil
            }
            // a switch-off saved by an older version (it waited for midnight) applies the new way: each strict block
            // keeps its lock until its own reset or the end of its run
            if s.strictLock, s.strictLockOffAt != nil, (s.lockInUntil ?? .distantPast) <= now {
                s.switchStrictOff(now: now, calendar: .autoupdatingCurrent) { Engine.status($0, now: now, calendar: .autoupdatingCurrent) }
            }
            // a hold ending this close counts as over (see `edge`), so a callback a moment early still frees the clock
            if s.strictUntil.contains(where: { $0.value.timeIntervalSince(now) <= edge }) {
                s.strictUntil = s.strictUntil.filter { $0.value.timeIntervalSince(now) > edge }
            }
            // a place block's hold lasts as long as its visit's block: gone once that's over (left, or its time is up)
            let idlePlaces = Set(s.rules.filter { $0.plan.kind == .place && !PlaceRules.isRunning(PlaceVisits.get($0.id), now: now) }
                .map(\.id.uuidString))
            if s.strictUntil.keys.contains(where: idlePlaces.contains) { s.strictUntil = s.strictUntil.filter { !idlePlaces.contains($0.key) } }
            if let sess = s.session, sess.endsAt <= now { s.session = nil }
            return (Pending.applyDue(&s.rules, now: now, frozenUntil: s.lockInUntil), moved)
        }
        var probe = st
        let (due, moved) = tidy(&probe)
        guard !due.isEmpty || moved || probe.session != st.session || probe.lockInUntil != st.lockInUntil
              || probe.deletionProtection != st.deletionProtection || probe.strictLock != st.strictLock
              || probe.strictUntil != st.strictUntil else { return (st, false) }
        st = StateStore.update { fresh in
            let before = fresh.rules
            let (ids, _) = tidy(&fresh)
            for id in ids {
                // the change restarts the count; old marks or credit would mean a different limit (e.g. after a
                // time-zone change applied it mid-day, or a new reset time) — start clean rather than risk a false lock
                Marks.clear(id)
                Credits.clear(id)
                // a new reset time: its new day may have begun before now, with use the old day already counted —
                // count from now until its first reset under the new time
                if let old = before.first(where: { $0.id == id }), let new = fresh.rules.first(where: { $0.id == id }),
                   new.plan.kind == .limit, old.plan.resetAt != new.plan.resetAt {
                    FreshCounts.set(id, until: Period.end(after: now, resetAt: new.plan.resetAt, calendar: .autoupdatingCurrent))
                }
                guard !fresh.rules.contains(where: { $0.id == id }) else { continue }
                FreshCounts.clear(id)
                if let slot = fresh.slot(of: id) { Shielding.clear(Names.store(slot: slot)) }
                Restarts.clear(id)
                Breaks.clear(id)
                Stops.clear(id)
                PlaceVisits.clear(id)
                Monitoring.stopPlaceEnd(id)
                Monitoring.forget(id)
            }
            fresh.assignSlots()
        }
        return (st, st.isSetUp)          // not set up: the fresh read failed and nothing was written
    }

    /// Whether `now` falls in a period (day, from the block's reset time) this limit or time-out counts.
    static func counts(_ rule: Rule, now: Date, calendar: Calendar = .current) -> Bool {
        rule.plan.isOn && rule.plan.kind.countsUse
            && rule.plan.days.contains(Period.weekday(containing: now, resetAt: rule.plan.resetAt, calendar: calendar))
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
