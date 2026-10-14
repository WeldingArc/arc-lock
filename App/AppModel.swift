// The app's view of the shared state, plus every change the user can make — each one checked against the lock
// policy first (Core/ArcCore.swift: running blocks are read-only, looser limits wait until midnight, lock-in
// freezes everything).
import Combine
import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state = StateStore.load()
    @Published private(set) var auth = AuthorizationCenter.shared.authorizationStatus
    @Published private(set) var now = Date()
    @Published var toast: String?
    @Published var problem: String?
    /// False until this launch has confirmed Screen Time access (a fresh process can read "not determined" at first).
    @Published private(set) var authChecked = false
    /// Set when iOS refuses to monitor because access was switched off in Settings.
    @Published private(set) var accessLost = false
    /// Bumped when the usage lines should ask iOS again (coming back to the app, or after a change).
    @Published private(set) var reportEpoch = 0

    /// Debug screenshots: sample state, fixed clock, no Screen Time calls.
    private var demo = false
    private var bag = Set<AnyCancellable>()
    private var ticker: AnyCancellable?
    private let calendar = Calendar.current

    init() {
        #if DEBUG
        if Demo.isOn {
            demo = true
            state = Demo.state()
            now = Demo.now
            authChecked = true
            return
        }
        #endif
        AuthorizationCenter.shared.$authorizationStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self else { return }
                let wasAuthorized = self.isAuthorized
                self.auth = status
                if !wasAuthorized && self.isAuthorized { self.refresh() }
            }
            .store(in: &bag)
        ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect().sink { [weak self] _ in self?.tick() }
        if #available(iOS 26.5, *) {
            NotificationCenter.default.publisher(for: ManagedSettingsStore.TokenExpiryMessage.name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refreshTokens() }
                .store(in: &bag)
        }
        refresh()
        Task { await checkAccess() }
    }

    var isAuthorized: Bool {
        if demo { return true }
        if accessLost { return false }
        return Self.granted(auth)
    }

    static func granted(_ status: AuthorizationStatus) -> Bool {
        // Only `.approved`: other statuses belong to the separate "App and Website Usage" entitlement, which
        // Arc Lock doesn't use (referencing them makes App Store review reject the build automatically).
        status == .approved
    }

    /// Asking again is silent while access is still granted, and the only reliable way to notice that it was
    /// switched off in Settings (the status publisher doesn't always fire).
    func checkAccess() async {
        defer { authChecked = true }
        if demo { return }
        guard state.onboarded else { return }
        // Without an Apple Account (e.g. in the Simulator) the request never returns: don't hold the screen for it.
        let patience = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            self?.authChecked = true
        }
        defer { patience.cancel() }
        if !isAuthorized || accessLost {
            try? await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        }
        auth = AuthorizationCenter.shared.authorizationStatus
        if Self.granted(auth) { accessLost = false }
        if isAuthorized { refresh() }
    }

    // MARK: reading

    func status(_ r: Rule) -> RuleStatus {
        #if DEBUG
        if demo { return Status.of(r.plan, now: now, reachedAt: reachedAt(r.id), breakUntil: Demo.breakUntil(r.id), calendar: calendar) }
        #endif
        return Status.of(r.plan, now: now, reachedAt: reachedAt(r.id), breakUntil: Breaks.until(r.id),
                         stoppedUntil: Stops.until(r.id), calendar: calendar)
    }
    private func reachedAt(_ id: UUID) -> Date? {
        #if DEBUG
        if demo { return Demo.reachedAt(id) }
        #endif
        return Marks.reachedAt(id)
    }
    func access(_ r: Rule) -> EditAccess {
        Policy.access(status: status(r), lockInUntil: state.lockInUntil, strict: state.isStrict(r.plan, now: now), now: now, calendar: calendar)
    }
    /// A running block (or break) that may be stopped by hand: not strict, or Strict lock is off in Settings.
    func canStop(_ r: Rule) -> Bool { status(r).isBlocking && access(r) == .free }
    var canStopSession: Bool { activeSession.map { !state.isStrict($0, now: now) } ?? false }
    var strictLockActive: Bool { state.strictLock }
    func usageLevel(_ r: Rule) -> Int {
        #if DEBUG
        if demo { return Demo.level(r.id) }
        #endif
        return Marks.level(r.id, now: now, calendar: calendar)
    }
    var lockInActive: Bool { Policy.lockInActive(state.lockInUntil, now: now) }
    var activeSession: FocusSession? { state.session.flatMap { $0.endsAt > now ? $0 : nil } }
    var schedules: [Rule] { state.rules.filter { $0.plan.kind == .schedule } }
    var limits: [Rule] { state.rules.filter { $0.plan.kind == .limit } }
    var timeouts: [Rule] { state.rules.filter { $0.plan.kind == .timeout } }
    /// Every block keeps a monitor and a store slot; iOS allows an app 20 monitors, so Arc Lock keeps up to 18 blocks.
    var canAddRule: Bool { canAdd(.limit) }
    func canAdd(_ kind: RuleKind) -> Bool { Capacity.fits(state.rules.map(\.plan) + [RulePlan(kind: kind)]) }

    /// Blocks holding something right now, soonest end first.
    var blockingNow: [(name: String, until: Date, kind: RuleKind?)] {
        var out = state.rules.compactMap { r -> (String, Date, RuleKind?)? in
            status(r).blockingUntil.map { (r.plan.name, $0, r.plan.kind) }
        }
        if let s = activeSession { out.append((String(localized: "Block now"), s.endsAt, nil)) }
        return out.sorted { $0.1 < $1.1 }.map { (name: $0.0, until: $0.1, kind: $0.2) }
    }

    var nextStart: (name: String, at: Date)? {
        state.rules.compactMap { r -> (String, Date)? in
            if case .waiting(let next?) = status(r) { return (r.plan.name, next) }
            return nil
        }.min { $0.1 < $1.1 }.map { (name: $0.0, at: $0.1) }
    }

    // MARK: lifecycle

    func refresh() {
        if demo { return }
        var (s, _) = Engine.housekeep()
        if s.rules.contains(where: { s.slot(of: $0.id) == nil }) { s = StateStore.update { $0.assignSlots() } }
        state = s
        now = Date()
        guard isAuthorized else { return }
        report(Monitoring.sync(s))
        Monitoring.finishBreaks(s)
        Engine.reconcile(s)
    }

    private func report(_ errors: [Error]) {
        if errors.contains(where: { ($0 as? DeviceActivityCenter.MonitoringError) == .unauthorized }) {
            accessLost = true
            return
        }
        if let e = errors.first { problem = Self.describe(e) }
    }

    /// iOS 26.5+: Apple can expire the opaque app tokens; swap in fresh ones and re-apply.
    private func refreshTokens() {
        guard #available(iOS 26.5, *) else { return }
        func fresh(_ sel: FamilyActivitySelection) -> FamilyActivitySelection {
            var s = sel
            var apps = Array(s.applicationTokens), cats = Array(s.categoryTokens), webs = Array(s.webDomainTokens)
            try? ManagedSettingsStore.refresh(&apps)
            try? ManagedSettingsStore.refresh(&cats)
            try? ManagedSettingsStore.refresh(&webs)
            s.applicationTokens = Set(apps); s.categoryTokens = Set(cats); s.webDomainTokens = Set(webs)
            return s
        }
        // fresh tokens re-register every limit, which restarts iOS's count: carry today's proven use over first
        for r in state.rules where r.plan.kind == .limit && status(r) == .counting {
            let used = LimitMath.usedAtLeast(level: usageLevel(r), limit: r.plan.limitMinutes)
            Credits.set(r.id, minutes: max(Credits.today(r.id, now: now), used), now: now)
        }
        commit { st in
            for i in st.rules.indices {
                st.rules[i].selection = fresh(st.rules[i].selection)
                if let p = st.rules[i].pending, let sel = p.selection { st.rules[i].pending?.selection = fresh(sel) }
            }
            if let sess = st.session { st.session?.selection = fresh(sess.selection) }
            if let last = st.lastSessionSelection { st.lastSessionSelection = fresh(last) }
        }
    }

    /// Coming back to the app: re-check everything and ask iOS for fresh usage minutes.
    func didBecomeActive() {
        reportEpoch += 1
        refresh()
    }

    private func tick() {
        if demo { return }
        let before = blockingNow.map(\.until)
        let previous = now
        now = Date()
        // re-check when a block, a session or a lock-in has just ended, or a pending change is due; a switch-off
        // that has to wait (for a lock-in or a running strict block) is re-checked when that ends
        let ended = before.contains { $0 <= now }
        let due = state.rules.contains { $0.pending.map { effectiveDate($0) <= now } ?? false }
        func newlyDue(_ d: Date?) -> Bool { d.map { $0 > previous && $0 <= now } ?? false }
        let switchDue = newlyDue(state.deletionProtectionOffAt) || newlyDue(state.strictLockOffAt)
        if ended || due || switchDue || (state.lockInUntil.map { $0 <= now } ?? false) { refresh() }
    }

    private func commit(_ change: (inout ArcState) -> Void) {
        if demo { change(&state); state.assignSlots(); return }
        state = StateStore.update { st in
            change(&st)
            st.assignSlots()
        }
        reportEpoch += 1
        guard isAuthorized else { return }
        report(Monitoring.sync(state))
        Engine.reconcile(state)
    }

    // MARK: onboarding & permissions

    func requestScreenTime() async -> Bool {
        do {
            try await AuthorizationCenter.shared.requestAuthorization(for: .individual)
        } catch {
            problem = String(localized: "Screen Time access wasn't granted. Arc Lock can't block anything without it.")
        }
        auth = AuthorizationCenter.shared.authorizationStatus
        if Self.granted(auth) { accessLost = false }
        if isAuthorized { refresh() }
        return isAuthorized
    }

    func requestNotifications() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func finishOnboarding() { commit { $0.onboarded = true } }

    func setHeadsUp(_ on: Bool) { commit { $0.headsUp = on } }

    // MARK: deletion protection

    /// Switching on applies now; switching off waits for midnight (and for a lock-in to end), like any looser change.
    func setDeletionProtection(_ on: Bool) -> Outcome {
        if !demo { now = Date() }
        if on {
            commit { $0.deletionProtection = true; $0.deletionProtectionOffAt = nil }
            return .saved
        }
        if lockInActive, let until = state.lockInUntil {
            return .refused(Self.lockedMessage(until: until, reason: .lockIn, now: now))
        }
        if !state.strictLock {
            commit { $0.deletionProtection = false; $0.deletionProtectionOffAt = nil }
            return .saved
        }
        let at = ScheduleMath.startOfNextDay(after: now, calendar: calendar)
        commit { $0.deletionProtectionOffAt = at }
        return .scheduled(at)
    }

    // MARK: strict lock

    /// The global Strict lock. On: blocks marked Strict lock can't be stopped or loosened while they run. Switching it
    /// on applies now; switching it off waits for midnight (never during a lock-in).
    func setStrictLock(_ on: Bool) -> Outcome {
        if !demo { now = Date() }
        if on {
            commit { $0.strictLock = true; $0.strictLockOffAt = nil }
            return .saved
        }
        if lockInActive, let until = state.lockInUntil {
            return .refused(Self.lockedMessage(until: until, reason: .lockIn, now: now))
        }
        let at = ScheduleMath.startOfNextDay(after: now, calendar: calendar)
        commit { $0.strictLockOffAt = at }
        return .scheduled(at)
    }

    /// Stops a running block that isn't strict, until it would have ended (a schedule's window, a limit's day, a
    /// time-out's break). It comes back on its own next time.
    func stop(_ id: UUID) -> Outcome {
        if !demo { now = Date() }
        guard let rule = state.rules.first(where: { $0.id == id }), let until = status(rule).blockingUntil else { return .saved }
        guard access(rule) == .free else {
            if case .locked(let u, let reason) = access(rule) { return .refused(Self.lockedMessage(until: u, reason: reason, now: now)) }
            return .refused(String(localized: "This block has Strict lock. It can't be stopped while it runs."))
        }
        if demo { return .saved }
        Stops.set(id, until: until)
        if rule.plan.kind == .timeout {
            // the break is over now: start counting toward the next one
            Breaks.set(id, until: now)
            Monitoring.finishBreaks(state, now: now)
        }
        Engine.reconcile(state, now: now)
        objectWillChange.send()
        return .saved
    }

    /// Ends a Block-now session that isn't strict.
    func stopSession() -> Outcome {
        if !demo { now = Date() }
        guard canStopSession else { return .refused(String(localized: "This Block now has Strict lock. It can't be stopped early.")) }
        commit { $0.session = nil }
        if !demo { DeviceActivityCenter().stopMonitoring([Names.session]) }
        return .saved
    }

    // MARK: rules

    enum Outcome: Equatable { case saved, scheduled(Date), refused(String) }

    func save(plan: RulePlan, selection: FamilyActivitySelection, id: UUID?) -> Outcome {
        if !demo { now = Date() }            // lock decisions always use the real clock, not the 15-second tick
        var plan = plan
        plan.name = plan.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if plan.kind.countsUse { plan.domains = [] }
        if plan.kind == .schedule && plan.isOn {
            let others = state.rules.filter { $0.id != id }.map(\.plan)
            guard Coverage.leavesFreeTime(others + [plan]) else {
                return .refused(String(localized: "Together your schedules would leave less than an hour a day free. Keep a free hour, so you can always open Arc Lock and change them."))
            }
        }
        // a change waiting for midnight counts too, if it needs more of iOS's monitors than the running version
        let others = state.rules.filter { $0.id != id }.map { r -> RulePlan in
            guard let p = r.pending?.plan, Capacity.activities(for: [p]) > Capacity.activities(for: [r.plan]) else { return r.plan }
            return p
        }
        guard Capacity.fits(others + [plan]) else {
            return .refused(String(localized: "iOS lets one app watch only so many blocks: up to \(Capacity.maxRules), and a time-out counts as two. Delete one first."))
        }
        guard let id, let existing = state.rules.first(where: { $0.id == id }) else {
            commit { $0.rules.append(Rule(plan: plan, selection: selection)) }
            return .saved
        }
        let dir = Change.direction(from: existing.plan, to: plan,
                                   selectionLost: selection.lost(from: existing.selection),
                                   selectionGained: selection.gained(over: existing.selection))
        switch access(existing) {
        case .locked(let until, let reason):
            return .refused(Self.lockedMessage(until: until, reason: reason, now: now))
        case .stricterOnly(let from) where dir == .looser:
            commit { st in
                guard let i = st.rules.firstIndex(where: { $0.id == id }) else { return }
                st.rules[i].pending = RuleChange(plan: plan, selection: selection, effectiveAt: from)
            }
            return .scheduled(from)
        default:
            // A new threshold or new apps restart the limit's count in iOS. Carry over what today's marks prove was
            // already used, so a stricter limit never hands out extra time (and locks at once if it's already used up).
            let restarts = plan.kind.countsUse && existing.plan.kind == plan.kind &&
                (plan.limitMinutes != existing.plan.limitMinutes || selection != existing.selection)
            if restarts, !demo, case .stricterOnly(let from) = access(existing),
               plan.kind == .timeout || Restarts.happenedToday(id, now: now) {
                // A restart hands out time already used: a time-out can't carry its count over (iOS reports only the
                // break threshold), and a second limit restart today would undo the first one's carry-over. Both wait
                // for midnight.
                commit { st in
                    guard let i = st.rules.firstIndex(where: { $0.id == id }) else { return }
                    st.rules[i].pending = RuleChange(plan: plan, selection: selection, effectiveAt: from)
                }
                return .scheduled(from)
            }
            // only a limit that is locked in for today needs the once-a-day rule; one that isn't strict can be stopped
            if restarts, !demo, plan.kind == .limit, status(existing) == .counting, case .stricterOnly = access(existing) {
                Restarts.mark(id, now: now)
            }
            // a block that becomes strict runs again, even if it was stopped by hand
            if !demo && state.isStrict(plan, now: now) && !state.isStrict(existing.plan, now: now) { Stops.clear(id) }
            if restarts && !demo && plan.kind == .limit {
                var used = 0
                if existing.plan.isOn && status(existing) == .counting {
                    used = max(Credits.today(id, now: now),
                               LimitMath.usedAtLeast(level: usageLevel(existing), limit: existing.plan.limitMinutes))
                }
                Marks.clear(id)
                Credits.set(id, minutes: plan.isOn ? used : 0, now: now)
                let level = LimitMath.level(forUsed: used, limit: plan.limitMinutes)
                if plan.isOn && level > 0 { Marks.raise(id, to: level, now: now) }
            }
            commit { st in
                guard let i = st.rules.firstIndex(where: { $0.id == id }) else { return }
                st.rules[i].plan = plan
                st.rules[i].selection = selection
                st.rules[i].pending = nil
            }
            return .saved
        }
    }

    func delete(_ id: UUID) -> Outcome {
        if !demo { now = Date() }
        guard let rule = state.rules.first(where: { $0.id == id }) else { return .saved }
        switch access(rule) {
        case .locked(let until, let reason):
            return .refused(Self.lockedMessage(until: until, reason: reason, now: now))
        case .stricterOnly(let from):
            commit { st in
                guard let i = st.rules.firstIndex(where: { $0.id == id }) else { return }
                st.rules[i].pending = RuleChange(plan: nil, selection: nil, effectiveAt: from)
            }
            return .scheduled(from)
        case .free:
            let store = Engine.store(for: id, in: state)
            commit { $0.rules.removeAll { $0.id == id } }
            if demo { return .saved }
            if let store { Shielding.clear(store) }
            Marks.clear(id)
            Credits.clear(id)
            Restarts.clear(id)
            Breaks.clear(id)
            Stops.clear(id)
            DeviceActivityCenter().stopMonitoring([Names.breakActivity(id)])
            Monitoring.forget(id)
            return .saved
        }
    }

    /// When a pending change really takes effect: its own time, or the end of a lock-in that holds it back.
    func effectiveDate(_ p: RuleChange) -> Date {
        if let l = state.lockInUntil, l > now, l > p.effectiveAt { return l }
        return p.effectiveAt
    }

    /// Undoing a pending looser change only makes things stricter, so it's always allowed — even during a lock-in.
    func cancelPending(_ id: UUID) {
        commit { st in
            guard let i = st.rules.firstIndex(where: { $0.id == id }) else { return }
            st.rules[i].pending = nil
        }
    }

    // MARK: block now

    func startSession(selection: FamilyActivitySelection, domains: [String], minutes: Int, strict: Bool = true) -> Outcome {
        if !demo { now = Date() }
        // iOS shields nothing at all when a set is over its cap — never show "Locked" for a block that isn't
        if selection.applicationTokens.count > Limits.maxApps || selection.webDomainTokens.count > Limits.maxDomains {
            return .refused(String(localized: "Choose at most \(Limits.maxApps) apps and \(Limits.maxDomains) websites — or pick whole categories instead."))
        }
        guard Limits.sessionMinutes.contains(minutes), !selection.isEmpty else {
            return .refused(String(localized: "Choose what to block and a time from 15 minutes to 12 hours."))
        }
        if let s = activeSession { return .refused(String(localized: "A Block now session is already running until \(Fmt.moment(s.endsAt)).")) }
        let start = Date()
        let session = FocusSession(startedAt: start, endsAt: start.addingTimeInterval(TimeInterval(minutes * 60)),
                                   selection: selection, domains: domains, strict: strict)
        commit { st in
            st.session = session
            st.lastSessionSelection = selection
            st.lastSessionMinutes = minutes
        }
        if demo { return .saved }
        Shielding.apply(selection, domains: domains, to: Names.sessionStore, hold: state.isStrict(session, now: now))
        do { try Monitoring.startSession(session) } catch { problem = Self.describe(error) }
        return .saved
    }

    // MARK: lock-in

    /// Locks every rule and stops app deletion through the end of the day `days` days from today.
    func startLockIn(days: Int) -> Outcome {
        if !demo { now = Date() }
        guard state.strictLock && state.strictLockOffAt == nil else {
            return .refused(String(localized: "Lock-in needs Strict lock. Turn Strict lock on in Settings first."))
        }
        let end = calendar.date(byAdding: .day, value: days + 1, to: calendar.startOfDay(for: Date()))!
        if let current = state.lockInUntil, current >= end, current > Date() {
            return .refused(String(localized: "A lock-in can be made longer, never shorter."))
        }
        commit { $0.lockInUntil = end }
        // a lock-in keeps every block as it is or stricter: blocks stopped by hand run again
        if !demo {
            for r in state.rules { Stops.clear(r.id) }
            Engine.reconcile(state)
        }
        return .saved
    }

    // MARK: messages

    static func lockedMessage(until: Date, reason: LockReason, now: Date) -> String {
        let when = Fmt.moment(until, now: now)
        switch reason {
        case .running, .session: return String(localized: "This block is running. It can't be changed until \(when).")
        case .reached: return String(localized: "Today's limit is used up. It can't be changed until \(when).")
        case .onBreak: return String(localized: "This time-out is on a break. It can't be changed until \(when).")
        case .lockIn: return String(localized: "You're locked in through \(Fmt.lastDay(endingAt: until)). Rules can't be changed until then.")
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? DeviceActivityCenter.MonitoringError {
            switch e {
            case .excessiveActivities: return String(localized: "Too many blocks for iOS to watch. Delete one.")
            case .intervalTooShort: return String(localized: "A block must last at least 15 minutes.")
            case .intervalTooLong: return String(localized: "That block is longer than iOS allows.")
            case .unauthorized: return String(localized: "Screen Time access is off. Allow it to keep blocking.")
            default: return error.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
