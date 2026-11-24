// The app's view of the shared state, plus every change the user can make — each one checked against the lock
// policy first (Core/ArcCore.swift: running blocks are read-only, looser limits wait for their own reset, lock-in
// freezes everything).
import Combine
import DeviceActivity
import FamilyControls
import Foundation
import ManagedSettings
import UIKit
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state = StateStore.load()
    @Published private(set) var auth = AuthorizationCenter.shared.authorizationStatus
    @Published private(set) var now = Date()
    @Published var toast: String?
    /// The selected tab, kept here so a theme change (which redraws every screen) stays on Settings.
    @Published var tab: AppTab = .home
    /// The setup page, kept here for the same reason (a new text size redraws every screen).
    @Published var setupPage = 0
    @Published var problem: String?
    /// False until this launch has confirmed Screen Time access (a fresh process can read "not determined" at first).
    @Published private(set) var authChecked = false
    /// Set when iOS refuses to monitor because access was switched off in Settings.
    @Published private(set) var accessLost = false
    /// Bumped when the usage lines should ask iOS again (coming back to the app, or after a change).
    @Published private(set) var reportEpoch = 0
    /// This process reads the shared data as empty although a set-up state is saved on disk: it read it before the
    /// first unlock after a restart, and iOS can keep answering empty until Arc Lock starts again. The app asks for
    /// that instead of showing setup (whose last step must never save over the real blocks, so it can't finish).
    @Published private(set) var needsRelaunch = false
    /// Blocks an older version lost (MissingBlocks): Home offers them back until each is restored or dismissed.
    @Published private(set) var missing: [Rule] = []

    /// Debug screenshots: sample state, fixed clock, no Screen Time calls.
    private var demo = false
    private var bag = Set<AnyCancellable>()
    private var ticker: AnyCancellable?
    /// Follows the iPhone's time zone as it changes (travel), so periods are computed like the extensions do.
    private var calendar: Calendar { .autoupdatingCurrent }

    init() {
        #if DEBUG
        if Demo.isOn {
            if let t = UserDefaults.standard.string(forKey: "theme").flatMap(ArcTheme.init(rawValue:)) { ArcTheme.current = t }
            tab = Demo.tab
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
        // after a restart nothing could be read before the first unlock: catch up as soon as it can
        NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        // a place block started or ended (iOS reported arriving or leaving)
        NotificationCenter.default.publisher(for: .placesChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        if #available(iOS 26.5, *) {
            NotificationCenter.default.publisher(for: ManagedSettingsStore.TokenExpiryMessage.name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refreshTokens() }
                .store(in: &bag)
        }
        refresh()
        checkStale()
        Task { await checkAccess() }
        #if DEBUG
        switch UserDefaults.standard.string(forKey: "probe") {
        case "start": Diag.startProbes(state); Diag.dumpMonitors()
        case "stop": Diag.stopProbes(); Diag.dumpMonitors()
        default: break
        }
        #endif
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

    /// Coming back to the app: is Screen Time access still there? A fresh process can read "not determined" for a
    /// moment, and asking is silent while access is still granted — so Arc Lock asks on its own once per launch,
    /// without waiting for the answer (on iPad it can come back late or never), and reads the status meanwhile. After
    /// that only the "access is off" screen's Continue asks: a "Don't Allow" must not bring iOS's question straight
    /// back every time the app becomes active. (Access switched off in Settings also shows up when monitoring is
    /// refused: `accessLost`.)
    func checkAccess() async {
        defer { authChecked = true }
        if demo { return }
        guard state.onboarded else { return }
        // the logo shows meanwhile; never for long (without an Apple Account iOS's answer never comes)
        let patience = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            self?.authChecked = true
        }
        defer { patience.cancel() }
        guard !isAuthorized || accessLost else { return }
        if !autoAsked {
            autoAsked = true
            askScreenTime()
        }
        guard !accessLost else { return }          // cleared once iOS answers the request (askScreenTime)
        for _ in 0..<12 {
            if recheckScreenTime() { return }       // refreshes once access is back
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Whether this launch has asked for Screen Time access on its own (see checkAccess).
    private var autoAsked = false
    /// When the last request for Screen Time access started (nil once it answered).
    private var askedAt: Date?

    /// Asks iOS for Screen Time access in the background (silent while it's still granted) and re-reads the status
    /// when the answer comes. One request at a time: a new one only after 30 seconds without an answer.
    private func askScreenTime() {
        if let at = askedAt, Date().timeIntervalSince(at) < 30 { return }
        askedAt = Date()
        Task {
            try? await AuthorizationCenter.shared.requestAuthorization(for: .individual)
            askedAt = nil
            recheckScreenTime()
        }
    }

    // MARK: reading

    func status(_ r: Rule) -> RuleStatus {
        #if DEBUG
        if demo {
            return Status.of(r.plan, now: now, reachedAt: reachedAt(r.id), breakUntil: Demo.breakUntil(r.id), visit: Demo.visit(r.id),
                             calendar: calendar)
        }
        #endif
        return Status.of(r.plan, now: now, reachedAt: reachedAt(r.id), breakUntil: Breaks.until(r.id),
                         stoppedUntil: Stops.until(r.id), visit: r.plan.kind == .place ? PlaceVisits.get(r.id) : nil,
                         calendar: calendar)
    }
    private func reachedAt(_ id: UUID) -> Date? {
        #if DEBUG
        if demo { return Demo.reachedAt(id) }
        #endif
        return Marks.reachedAt(id)
    }
    func access(_ r: Rule) -> EditAccess {
        Policy.access(status: status(r), lockInUntil: state.lockInUntil, strict: state.isStrict(r, now: now), now: now, calendar: calendar,
                      nextReset: r.plan.kind.countsUse ? nextReset(r.plan) : nil)
    }
    /// A running block (or break) that may be stopped by hand: not strict, or Strict lock is off in Settings.
    func canStop(_ r: Rule) -> Bool { status(r).isBlocking && access(r) == .free }
    var canStopSession: Bool { activeSession.map { !state.isStrict($0, now: now) } ?? false }
    var strictLockActive: Bool { state.strictLock }
    /// With Strict lock off: until when this block keeps it (it was running or counting when Strict lock went off).
    func strictHold(_ r: Rule) -> Date? {
        guard !state.strictLock, r.plan.strict, let until = state.strictUntil[r.id.uuidString], until > now else { return nil }
        return until
    }
    /// "5:00 PM", or "you leave" for a running place block that ends when you leave.
    func holdText(_ r: Rule, _ until: Date) -> String {
        if r.plan.kind == .place, r.plan.untilLeave, case .atPlace = status(r) { return String(localized: "you leave") }
        return Fmt.moment(until, now: now)
    }
    /// The blocks still keeping Strict lock after it was turned off, soonest first.
    var heldRules: [Rule] {
        state.rules.filter { strictHold($0) != nil }.sorted { (strictHold($0) ?? now) < (strictHold($1) ?? now) }
    }
    /// A Block now keeping Strict lock after it was turned off.
    var sessionHeld: Bool { activeSession.map { !state.strictLock && state.isStrict($0, now: now) } ?? false }
    func usageLevel(_ r: Rule) -> Int {
        #if DEBUG
        if demo { return Demo.level(r.id) }
        #endif
        return Marks.level(r.id, period: periodStart(r.plan))
    }
    var lockInActive: Bool { Policy.lockInActive(state.lockInUntil, now: now) }
    /// When a daily limit's or time-out's current period began, and when it resets next.
    func periodStart(_ p: RulePlan) -> Date { Period.start(containing: now, resetAt: p.resetAt, calendar: calendar) }
    func nextReset(_ p: RulePlan) -> Date { Period.end(after: now, resetAt: p.resetAt, calendar: calendar) }
    var activeSession: FocusSession? { state.session.flatMap { $0.endsAt > now ? $0 : nil } }
    var schedules: [Rule] { state.rules.filter { $0.plan.kind == .schedule } }
    var limits: [Rule] { state.rules.filter { $0.plan.kind == .limit } }
    var timeouts: [Rule] { state.rules.filter { $0.plan.kind == .timeout } }
    var places: [Rule] { state.rules.filter { $0.plan.kind == .place } }
    /// Whether you're at a place block's place right now (as iOS last reported).
    func isAtPlace(_ r: Rule) -> Bool {
        #if DEBUG
        if demo { return Demo.visit(r.id)?.inside ?? false }
        #endif
        return PlaceVisits.get(r.id)?.inside ?? false
    }
    /// Every block keeps a monitor and a store slot; iOS allows an app 20 monitors, so Arc Lock keeps up to 18 blocks
    /// (17 while emergency relief is on: its monitor keeps one block's place).
    var canAddRule: Bool { canAdd(.limit) }
    func canAdd(_ kind: RuleKind) -> Bool {
        Capacity.fits(state.rules.map(\.plan) + [RulePlan(kind: kind)], reserved: state.unreadRules.count, relief: state.reliefKeepsSlot)
    }
    /// The blocks as they count toward iOS's monitors: a change waiting for its reset counts too, if it needs more
    /// monitors than the running version. `except` = the block being saved.
    private func capacityPlans(except id: UUID? = nil) -> [RulePlan] {
        state.rules.filter { $0.id != id }.map { r -> RulePlan in
            guard let p = r.pending?.plan, Capacity.activities(for: [p]) > Capacity.activities(for: [r.plan]) else { return r.plan }
            return p
        }
    }

    /// Blocks holding something right now, soonest end first. A place block running until you leave has no end:
    /// its `until` is `.distantFuture` (shown as "until you leave").
    var blockingNow: [(name: String, until: Date, kind: RuleKind?, rule: Rule?)] {
        var out = state.rules.compactMap { r -> (String, Date, RuleKind?, Rule?)? in
            let s = status(r)
            if case .atPlace = s { return (r.plan.displayName, .distantFuture, r.plan.kind, r) }
            return s.blockingUntil.map { (r.plan.displayName, $0, r.plan.kind, r) }
        }
        if let s = activeSession { out.append((String(localized: "Block now"), s.endsAt, nil, nil)) }
        return out.sorted { $0.1 < $1.1 }.map { (name: $0.0, until: $0.1, kind: $0.2, rule: $0.3) }
    }

    var nextStart: (rule: Rule, at: Date)? {
        state.rules.compactMap { r -> (Rule, Date)? in
            if case .waiting(let next?) = status(r) { return (r, next) }
            return nil
        }.min { $0.1 < $1.1 }.map { (rule: $0.0, at: $0.1) }
    }

    // MARK: lifecycle

    func refresh() {
        if demo { return }
        // before the first unlock after a restart the shared state can't be read and looks empty: acting on it
        // would lift every block
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        var (s, _) = Engine.housekeep()
        if s.rules.contains(where: { s.slot(of: $0.id) == nil }) { s = StateStore.update { $0.assignSlots() } }
        state = s
        now = Date()
        checkStale()
        missing = MissingBlocks.list(missingFrom: s)
        guard isAuthorized else { return }
        report(Monitoring.sync(s))
        Monitoring.finishBreaks(s)
        Engine.reconcile(s)
        PlaceWatcher.shared.sync(s)
        Diag.dumpMonitors()
    }

    /// See `needsRelaunch`: nothing at all comes back from the shared data, yet the file on disk holds a set-up state
    /// (a state that's there but can't be decoded is a different case, kept as `.unreadable`).
    private func checkStale() {
        needsRelaunch = !state.isSetUp && !StateStore.isSaved && StateStore.setUpOnDisk
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
        // fresh tokens register every limit again: iOS then counts its whole day again, earlier use included
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
        if !demo { PlaceWatcher.shared.recheck() }
    }

    private func tick() {
        if demo { return }
        let before = blockingNow.map(\.until)
        let previous = now
        now = Date()
        // re-check when a block, a session or a lock-in has just ended, or a pending change is due; a switch-off
        // that has to wait (for a lock-in or a running strict block) is re-checked when that ends
        let ended = before.contains { $0 <= now }
        let due = state.rules.contains { r in r.pending.map { effectiveDate($0, plan: r.plan) <= now } ?? false }
        func newlyDue(_ d: Date?) -> Bool { d.map { $0 > previous && $0 <= now } ?? false }
        let switchDue = newlyDue(state.deletionProtectionOffAt) || state.strictUntil.values.contains(where: newlyDue)
            || places.contains { newlyDue(PlaceRules.latestEnd(PlaceVisits.get($0.id), now: previous)) }
            // an emergency relief's end, a moment early as everywhere (Engine.edge): its shields come back
            || newlyDue(Relief.until?.addingTimeInterval(-Engine.edge))
            // emergency relief switched on while strict blocks ran: it turns on now
            || newlyDue(state.reliefOnAt)
        if ended || due || switchDue || (state.lockInUntil.map { $0 <= now } ?? false) { refresh() }
    }

    /// Saves a change and makes the monitors and shields match it. `force` = blocks whose monitors are registered
    /// again even if unchanged (see Monitoring.sync).
    private func commit(force: Set<UUID> = [], _ change: (inout ArcState) -> Void) {
        if demo { change(&state); state.assignSlots(); return }
        // setting up (onboarding) writes a state that isn't set up yet: only while the iPhone is unlocked, and only if no
        // set-up state is saved on disk — a process that read the shared data before the first unlock after a restart
        // can keep getting it empty after the unlock (shown as onboarding to someone with blocks), and would replace it
        state = StateStore.update(settingUp: UIApplication.shared.isProtectedDataAvailable && !StateStore.setUpOnDisk) { st in
            change(&st)
            st.assignSlots()
        }
        reportEpoch += 1
        PlaceWatcher.shared.sync(state)
        guard isAuthorized else { return }
        report(Monitoring.sync(state, force: force))
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

    /// Reads Screen Time access again. iOS's answer can arrive without the request ever returning or the status
    /// publisher firing (as on iPad), so setup looks for it itself.
    @discardableResult func recheckScreenTime() -> Bool {
        if demo { return true }
        let wasAuthorized = isAuthorized
        auth = AuthorizationCenter.shared.authorizationStatus
        if Self.granted(auth) { accessLost = false }
        if !wasAuthorized && isAuthorized { refresh() }
        return isAuthorized
    }

    /// Shows iOS's notification request; a "Don't Allow" there switches heads-ups off (Settings can turn them on again).
    func requestNotifications() async {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        if !granted { setHeadsUp(false) }
    }

    /// Whether iOS's notifications are off for Arc Lock (heads-ups can't arrive then).
    static func notificationsOff() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .denied
    }

    /// Heads-ups switched on in Settings: if iOS never asked about notifications (setup was left early, or an older
    /// version), ask now — without waiting for the answer.
    func headsUpOn() async {
        guard await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined else { return }
        Task { await requestNotifications() }
    }

    func finishOnboarding() { commit { $0.onboarded = true } }

    func setHeadsUp(_ on: Bool) { commit { $0.headsUp = on } }

    // MARK: deletion protection

    /// Switching on applies now. Switching off applies now too, unless a block with Strict lock is running or
    /// counting: then it waits until each such block has reset or ended (its own time, not midnight). Never during a
    /// lock-in.
    func setDeletionProtection(_ on: Bool) -> Outcome {
        if !demo { now = Date() }
        if on {
            commit { $0.deletionProtection = true; $0.deletionProtectionOffAt = nil }
            return .saved
        }
        if lockInActive, let until = state.lockInUntil {
            return .refused(Self.lockInSettingMessage(until: until))
        }
        guard let at = state.strictHoldsEnd(now: now, calendar: calendar, status: { self.status($0) }), at > now else {
            commit { $0.deletionProtection = false; $0.deletionProtectionOffAt = nil }
            return .saved
        }
        commit { $0.deletionProtectionOffAt = at }
        return .scheduled(at)
    }

    // MARK: strict lock

    /// The global Strict lock. On: blocks marked Strict lock can't be stopped or loosened while they run. Both ways
    /// apply now; switching off keeps each strict block that is running or counting locked until its own reset, or
    /// until its run ends (see `heldRules`). Never switched off during a lock-in.
    func setStrictLock(_ on: Bool) -> Outcome {
        if !demo { now = Date() }
        if on {
            commit { $0.strictLock = true; $0.strictLockOffAt = nil; $0.strictUntil = [:] }
            return .saved
        }
        if lockInActive, let until = state.lockInUntil {
            return .refused(Self.lockInSettingMessage(until: until))
        }
        let at = now
        commit { $0.switchStrictOff(now: at, calendar: calendar, status: { self.status($0) }) }
        return .saved
    }

    /// Stops a running block that isn't strict, until it would have ended (a schedule's window, a limit's day, a
    /// time-out's break). It comes back on its own next time.
    func stop(_ id: UUID) -> Outcome {
        if !demo { now = Date() }
        guard let rule = state.rules.first(where: { $0.id == id }), status(rule).isBlocking else { return .saved }
        guard access(rule) == .free else {
            if case .locked(let u, let reason) = access(rule) { return .refused(Self.lockedMessage(until: u, reason: reason, now: now)) }
            return .refused(String(localized: "This block has Strict lock. It can't be stopped while it runs."))
        }
        if demo { return .saved }
        if rule.plan.kind == .place {
            // over for this visit: it starts again the next time you arrive
            PlaceVisits.set(id, PlaceRules.stop(PlaceVisits.get(id), now: now))
            Monitoring.stopPlaceEnd(id)
            Engine.reconcile(state, now: now)
            objectWillChange.send()
            return .saved
        }
        guard let until = status(rule).blockingUntil else { return .saved }
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
        if plan.kind == .schedule && plan.isOn {
            let others = state.rules.filter { $0.id != id }.map(\.plan)
            guard Coverage.leavesFreeTime(others + [plan]) else {
                return .refused(String(localized: "Together your schedules would leave less than an hour a day free. Keep a free hour, so you can always open Arc Lock and change them."))
            }
        }
        // a change waiting for its reset counts too, if it needs more of iOS's monitors than the running version; while
        // emergency relief is on (or waiting to switch on), its monitor keeps one block's place
        let others = capacityPlans(except: id)
        guard Capacity.fits(others + [plan], reserved: id == nil ? state.unreadRules.count : 0, relief: state.reliefKeepsSlot) else {
            if state.reliefKeepsSlot {
                return .refused(String(localized: "iOS lets one app watch only so many blocks: up to \(Capacity.maxRules(relief: true)) while emergency relief is on, and a time-out counts as two. Delete one first, or turn emergency relief off."))
            }
            return .refused(String(localized: "iOS lets one app watch only so many blocks: up to \(Capacity.maxRules), and a time-out counts as two. Delete one first."))
        }
        if plan.kind == .place {
            let elsewhere = state.rules.filter { $0.id != id && $0.plan.kind == .place }.reduce(0) { $0 + $1.plan.places.count }
            guard elsewhere + plan.places.count <= Limits.maxPlaces else {
                return .refused(String(localized: "iOS lets one app watch up to \(Limits.maxPlaces) places in all. Remove a place first."))
            }
        }
        guard let id, let existing = state.rules.first(where: { $0.id == id }) else {
            commit { $0.rules.append(Rule(plan: plan, selection: selection)) }
            return .saved
        }
        let lost = selection.lost(from: existing.selection), gained = selection.gained(over: existing.selection)
        let dir = Change.direction(from: existing.plan, to: plan, selectionLost: lost, selectionGained: gained)
        switch access(existing) {
        case .locked(let until, let reason):
            // Running with Strict lock, used up, on a break or during a lock-in: more apps and websites still apply
            // at once (only stricter), nothing else does.
            guard Change.onlyAdds(from: existing.plan, to: plan, selectionLost: lost, selectionGained: gained) else {
                return .refused(Self.lockedMessage(until: until, reason: reason, now: now))
            }
            return apply(plan, selection, to: existing, keepPending: true)
        case .stricterOnly(let from) where dir == .looser:
            // The editor shows the change waiting for the reset; if this save only adds apps or websites to it, those
            // apply to the running version now (and the waiting change keeps them), like any addition.
            if let waiting = existing.pending, let waitingPlan = waiting.plan {
                let waitingSelection = waiting.selection ?? existing.selection
                if Change.onlyAdds(from: waitingPlan, to: plan, selectionLost: selection.lost(from: waitingSelection),
                                   selectionGained: selection.gained(over: waitingSelection)) {
                    let added = selection.subtracting(waitingSelection)
                    let addedDomains = plan.domains.filter { !waitingPlan.domains.contains($0) }
                    var running = existing.plan
                    for d in addedDomains where !running.domains.contains(d) { running.domains.append(d) }
                    // (an app the waiting change takes out and you put back stays in it, too)
                    return apply(running, existing.selection.adding(added), to: existing, keepPending: true,
                                 pendingAdditions: (added, addedDomains))
                }
            }
            commit { st in
                guard let i = st.rules.firstIndex(where: { $0.id == id }) else { return }
                st.rules[i].pending = RuleChange(plan: plan, selection: selection, effectiveAt: from)
            }
            return .scheduled(from)
        default:
            return apply(plan, selection, to: existing, keepPending: false)
        }
    }

    /// Applies a saved change now. `keepPending` = only apps or websites were added to a locked block: a change
    /// already waiting for its reset stays queued and gets the same additions (`pendingAdditions`, or else what's new
    /// over the running version), so they aren't undone when it lands.
    private func apply(_ plan: RulePlan, _ selection: FamilyActivitySelection, to existing: Rule, keepPending: Bool,
                       pendingAdditions: (FamilyActivitySelection, [String])? = nil) -> Outcome {
        let id = existing.id
        // iOS silently shields nothing for a set over its cap: neither the running version nor a waiting change that
        // gets the additions may go over it
        var merged: RuleChange?
        if keepPending, let p = existing.pending {
            merged = p.adding(pendingAdditions?.0 ?? selection.subtracting(existing.selection),
                              domains: pendingAdditions?.1 ?? plan.domains.filter { !existing.plan.domains.contains($0) })
        }
        func overCap(_ s: FamilyActivitySelection?, _ domains: [String]?) -> Bool {
            (s.map { $0.applicationTokens.count > Limits.maxApps || $0.webDomainTokens.count > Limits.maxDomains } ?? false)
                || (domains?.count ?? 0) > Limits.maxDomains
        }
        if overCap(selection, plan.domains) || overCap(merged?.selection, merged?.plan?.domains) {
            return .refused(String(localized: "Choose at most \(Limits.maxApps) apps and \(Limits.maxDomains) websites — or pick whole categories instead."))
        }
        let lost = selection.lost(from: existing.selection)
        // A new threshold, new apps or a new reset time make iOS count the block again. A daily limit then counts its
        // whole day, use from before the change included (Monitoring.plan): a stricter limit applies at once, and locks
        // at once if that use already fills it. A time-out — or a limit counting from registration, right after its
        // reset time changed — keeps the use its marks prove (Monitoring.credit): its count goes on, not over.
        let restarts = plan.kind.countsUse && existing.plan.kind == plan.kind &&
            (plan.limitMinutes != existing.plan.limitMinutes || selection != existing.selection || plan.resetAt != existing.plan.resetAt)
        // a block that becomes strict runs again, even if it was stopped by hand
        if !demo && state.isStrict(plan, id: id, now: now) && !state.isStrict(existing.plan, id: id, now: now) { Stops.clear(id) }
        // a place block with another place, ending or days starts over: iOS says again where you are
        let placeRestarts = !demo && existing.plan.kind == .place && PlaceRules.restartsVisit(from: existing.plan, to: plan)
        if placeRestarts {
            PlaceVisits.clear(id)
            Monitoring.stopPlaceEnd(id)
        }
        defer { if placeRestarts { PlaceWatcher.shared.recheck(id) } }
        var breakNow = false
        if restarts && !demo {
            let newPeriod = plan.resetAt != existing.plan.resetAt
            // a limit's new reset time: the new day may have begun before now, with use the old day already counted —
            // it counts from now until its first reset under the new time (Monitoring.plan)
            if newPeriod && plan.kind == .limit {
                FreshCounts.set(id, until: Period.end(after: now, resetAt: plan.resetAt, calendar: calendar))
            }
            // the use so far this period (a time-out: this stretch of use), as its marks prove it, goes on counting: the
            // bar shows it until iOS reports the new count, and a count that starts at registration starts from it
            // (Monitoring.credit). Not when an app was taken out (its use may be in there) or a new period begins. The
            // same limit keeps its mark exactly (LimitMath.carriedLevel), so adding apps never hands time out again.
            var level = 0
            if existing.plan.isOn, Engine.counts(existing, now: now, calendar: calendar) {
                level = LimitMath.carriedLevel(level: usageLevel(existing), oldLimit: existing.plan.limitMinutes,
                                               newLimit: plan.limitMinutes, selectionLost: lost, startsOver: newPeriod)
            }
            Marks.clear(id)
            Credits.clear(id)          // carried-over use from versions before 1.1.1: the new count includes it
            if plan.isOn && level > 0 {
                // a time-out made shorter than the use so far: its break is due now
                if plan.kind == .timeout && level >= 10 { breakNow = true }
                else { Marks.raise(id, to: level, now: now, period: periodStart(plan)) }
            }
        }
        // A limit or time-out that starts counting today because of this change (today added to its days): iOS kept
        // counting while it rested, and a threshold it passed then (ignored) isn't reported again today, so it's
        // registered again — a limit then counts today's use at once, a time-out from now.
        var updated = existing
        updated.plan = plan
        let startsCounting = !demo && plan.kind.countsUse && Engine.counts(updated, now: now, calendar: calendar)
            && !Engine.counts(existing, now: now, calendar: calendar)
        commit(force: startsCounting ? [id] : []) { st in
            guard let i = st.rules.firstIndex(where: { $0.id == id }) else { return }
            st.rules[i].plan = plan
            st.rules[i].selection = selection
            if keepPending, let p = st.rules[i].pending {
                let more = pendingAdditions ?? (selection.subtracting(existing.selection), plan.domains.filter { !existing.plan.domains.contains($0) })
                st.rules[i].pending = merged ?? p.adding(more.0, domains: more.1)
            } else {
                st.rules[i].pending = nil
            }
        }
        if breakNow, let rule = state.rules.first(where: { $0.id == id }), (Breaks.until(id) ?? .distantPast) <= now {
            Monitoring.startBreak(rule, now: now)
            // as for a break the monitor starts: a time-out still keeping Strict lock after it was switched off stays
            // strict until this break ends, even past its reset
            let back = now.addingTimeInterval(TimeInterval(rule.plan.breakMinutes * 60))
            if !state.strictLock, let held = state.strictUntil[id.uuidString], held > now, held < back {
                commit { _ = $0.holdThroughBreak(id, until: back, now: now) }
            }
            Engine.reconcile(state, now: now)
            toast = L("Time for a %@ break. Back at %@.", minutesText(rule.plan.breakMinutes), Fmt.time(back))
        }
        return .saved
    }

    /// Puts a lost block back as it was saved (a change it had waiting is dropped), checked like a new block. It starts
    /// working at once.
    func restore(_ id: UUID) -> Outcome {
        guard let r = missing.first(where: { $0.id == id }) else { return .saved }
        let outcome = save(plan: r.plan, selection: r.selection, id: nil)
        if case .refused = outcome { return outcome }
        if !demo { MissingBlocks.markHandled([id]) }
        missing.removeAll { $0.id == id }
        return outcome
    }

    /// Stops offering the lost blocks back (they stay in the backup copy).
    func dismissMissing() {
        if !demo { MissingBlocks.markHandled(missing.map(\.id)) }
        missing = []
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
            FreshCounts.clear(id)
            Breaks.clear(id)
            Stops.clear(id)
            PlaceVisits.clear(id)
            DeviceActivityCenter().stopMonitoring([Names.breakActivity(id), Names.placeActivity(id)])
            Monitoring.forget(id)
            return .saved
        }
    }

    /// When a pending change really takes effect: its own time, or the end of a lock-in that holds it back.
    func effectiveDate(_ p: RuleChange, plan: RulePlan) -> Date {
        Pending.effectiveDate(p.effectiveAt, plan: plan, lockInUntil: state.lockInUntil, now: now, calendar: calendar)
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
        guard Limits.sessionMinutes.contains(minutes), !selection.isEmpty || !domains.isEmpty else {
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
        Shielding.apply(selection, domains: domains, to: Names.sessionStore, hold: state.isStrict(session, now: now), now: now)
        do { try Monitoring.startSession(session) } catch { problem = Self.describe(error) }
        // an emergency relief lifts this one too: it covers its apps once the relief is over
        if reliefActive, let back = Relief.until {
            toast = String(localized: "Block now starts when emergency relief ends, at \(Fmt.time(back)).")
        }
        return .saved
    }

    /// Adds apps and websites to the running Block now. Always allowed — even with Strict lock or during a lock-in —
    /// since it only blocks more; nothing can be taken out and its end stays.
    func addToSession(_ more: FamilyActivitySelection) -> Outcome {
        if !demo { now = Date() }
        guard let s = activeSession else { return .refused(String(localized: "Block now isn't running.")) }
        let merged = s.selection.adding(more)
        if merged.applicationTokens.count > Limits.maxApps || merged.webDomainTokens.count > Limits.maxDomains {
            return .refused(String(localized: "Choose at most \(Limits.maxApps) apps and \(Limits.maxDomains) websites — or pick whole categories instead."))
        }
        guard merged != s.selection else { return .saved }
        commit { st in
            guard st.session?.id == s.id else { return }
            st.session?.selection = merged
            st.lastSessionSelection = merged
        }
        return .saved
    }

    // MARK: emergency relief

    /// The emergency relief setting (Josh, 1.2.1: off by default, also for anyone updating). Switching on loosens
    /// things, so it waits like deletion protection's switch-off: never during a lock-in, and only once each strict block
    /// running or counting now has reset or ended (its own time). Its monitor needs one block's place, so it's refused
    /// with more than 17 blocks. Switching off applies now: it cancels a switch-on that's waiting and ends a running
    /// relief, so the shields come back at once. When the next relief comes stays as it is: switching off and on again
    /// gives no new one.
    func setRelief(_ on: Bool) -> Outcome {
        if !demo { now = Date() }
        guard on else {
            if !demo, Relief.until != nil {
                Relief.close()                                          // commit's reconcile shields everything again
                DeviceActivityCenter().stopMonitoring([Names.relief])
            }
            commit { $0.reliefEnabled = false; $0.reliefOnAt = nil }
            return .saved
        }
        if state.reliefEnabled {
            if state.reliefOnAt != nil { commit { $0.reliefOnAt = nil } }
            return .saved
        }
        let fits = Capacity.fits(capacityPlans(), reserved: state.unreadRules.count, relief: true)
        // a strict place block running until you leave holds it too, until its latest end: a relief would lift it
        let holds = state.strictHoldsEnd(now: now, calendar: calendar, status: { self.status($0) }, untilLeave: true)
        switch ReliefRules.switchOn(lockInUntil: state.lockInUntil, strictHoldsEnd: holds, fits: fits, now: now) {
        case .lockedIn(let until):
            return .refused(Self.lockInSettingMessage(until: until))
        case .full:
            return .refused(String(localized: "Emergency relief takes one block's place, so with it on you can have up to \(Capacity.maxRules(relief: true)) blocks. Delete a block first."))
        case .at(let at):
            commit { $0.reliefOnAt = at }
            return .scheduled(at)
        case .now:
            commit { $0.reliefEnabled = true; $0.reliefOnAt = nil }
            return .saved
        }
    }

    /// Whether an emergency relief is lifting every block right now (Shared Relief, Core ReliefRules).
    var reliefActive: Bool { !demo && state.reliefEnabled && Relief.isActive(now: now) }
    /// When the running relief's blocks come back.
    var reliefUntil: Date? { reliefActive ? Relief.until : nil }
    /// When the next relief can be used, while the last one is less than 30 days old (nil: one is waiting).
    var reliefNextAvailable: Date? {
        guard !demo, let next = Relief.next, next > now else { return nil }
        return next
    }
    /// When the next relief would come if one were used now.
    var reliefRefill: Date { ReliefRules.plan(startingAt: now, calendar: calendar).next }

    /// Why an emergency relief can't start now, or nil when it can (asked before the warning and the hold).
    func reliefRefusal() -> String? {
        guard state.reliefEnabled else { return String(localized: "Emergency relief is off. You can turn it on in Settings.") }
        switch ReliefRules.refusal(until: Relief.until, next: Relief.next, anythingBlocked: !blockingNow.isEmpty,
                                   now: Date(), edge: Engine.edge) {
        case .running(let until)?:
            return String(localized: "Emergency relief is already on. Your blocks return at \(Fmt.time(until)).")
        case .notYet(let next)?:
            return String(localized: "You've used your emergency relief. The next one is available on \(Fmt.dayAndTime(next)).")
        case .nothingBlocked?:
            return String(localized: "Nothing is blocked right now, so there's nothing to lift.")
        case nil:
            return nil
        }
    }

    /// Lifts every block's shields for 30 minutes, once every 30 days (Core ReliefRules), strict blocks and lock-ins
    /// included. Rules, limits, the lock-in and every setting stay as they are, and a strict block still stops app
    /// deletion and manual clock changes. A one-off monitor brings the shields back at the end even if Arc Lock stays
    /// closed (Monitoring.startRelief); when iOS won't take it, nothing is lifted.
    func startRelief() -> Outcome {
        if !demo { now = Date() }
        if let why = reliefRefusal() { return .refused(why) }
        if demo { return .saved }
        let start = Date()
        let plan = ReliefRules.plan(startingAt: start, calendar: calendar)
        let before = Relief.saved
        Relief.begin(start: start, until: plan.until, next: plan.next)
        do {
            try Monitoring.startRelief(from: start, until: plan.until)
        } catch {
            Relief.restore(before)
            Engine.reconcile(state)
            Diag.log("relief monitor FAILED: \(error)")
            if (error as? DeviceActivityCenter.MonitoringError) == .excessiveActivities {
                return .refused(String(localized: "iOS is watching as many blocks as it allows, so emergency relief couldn't set its end. Nothing was lifted."))
            }
            return .refused(Self.describe(error))
        }
        Diag.log("relief until \(plan.until), next \(plan.next)")
        Engine.reconcile(state, now: start)
        objectWillChange.send()
        return .saved
    }

    // MARK: lock-in

    /// Why a lock-in of `days` days can't start now, or nil when it can (asked before the warning and the hold).
    func lockInRefusal(days: Int, end: Date? = nil) -> String? {
        guard state.strictLock else {
            return String(localized: "Lock-in needs Strict lock. Turn Strict lock on in Settings first.")
        }
        guard Limits.lockInDays.contains(days) else { return String(localized: "A lock-in lasts 1 to 14 days.") }
        if let current = state.lockInUntil, current >= end ?? lockInEnd(days: days), current > Date() {
            return String(localized: "A lock-in can be made longer, never shorter.")
        }
        return nil
    }

    /// The end of the day `days` days from today (also what the Lock in screens show).
    func lockInEnd(days: Int) -> Date {
        calendar.date(byAdding: .day, value: days + 1, to: calendar.startOfDay(for: Date()))!
    }

    /// Locks every rule and stops app deletion through the end of the day `days` days from today (14 at most), or
    /// through `shownEnd` — the end the confirmation screen showed — if midnight passed while it was open: that's
    /// what the person agreed to (never later than allowed).
    func startLockIn(days: Int, shownEnd: Date? = nil) -> Outcome {
        if !demo { now = Date() }
        var end = lockInEnd(days: days)
        if let shownEnd, shownEnd > Date(), shownEnd < end { end = shownEnd }
        if let why = lockInRefusal(days: days, end: end) { return .refused(why) }
        commit { $0.lockInUntil = end }
        // a lock-in keeps every block as it is: blocks stopped by hand run again
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
        case .atPlace: return String(localized: "This block runs until you leave. It can't be changed before then.")
        case .reached: return String(localized: "This limit is used up. It can't be changed until \(when).")
        case .onBreak: return String(localized: "This time-out is on a break. It can't be changed until \(when).")
        case .lockIn: return String(localized: "You're locked in through \(Fmt.lastDay(endingAt: until)). Until then you can only add apps and websites to a block.")
        }
    }

    /// A setting (Strict lock, deletion protection) refused during a lock-in.
    static func lockInSettingMessage(until: Date) -> String {
        String(localized: "You're locked in through \(Fmt.lastDay(endingAt: until)). This setting can't be changed until then.")
    }

    /// The editor's note on a locked block: what can't change until when, and that apps and websites can still be added.
    static func addOnlyMessage(until: Date, reason: LockReason, now: Date) -> String {
        let when = Fmt.moment(until, now: now)
        switch reason {
        case .running, .session: return String(localized: "This block is running. You can add apps and websites now; nothing else can change until \(when).")
        case .atPlace: return String(localized: "This block runs until you leave. You can add apps and websites now; nothing else can change before then.")
        case .reached: return String(localized: "This limit is used up. You can add apps and websites now; nothing else can change until \(when).")
        case .onBreak: return String(localized: "This time-out is on a break. You can add apps and websites now; nothing else can change until \(when).")
        case .lockIn: return String(localized: "You're locked in through \(Fmt.lastDay(endingAt: until)). You can add apps and websites now; nothing else can change until then.")
        }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? DeviceActivityCenter.MonitoringError {
            switch e {
            case .excessiveActivities: return String(localized: "Too many blocks for iOS to watch. Delete one.")
            case .intervalTooShort: return String(localized: "A block must last at least 15 minutes.")
            case .intervalTooLong: return String(localized: "That block is longer than iOS allows.")
            case .unauthorized: return String(localized: "Screen Time access is off. Turn it on again to keep blocking.")
            default: return error.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
