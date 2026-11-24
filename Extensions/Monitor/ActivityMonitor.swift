// Runs in the background when a schedule starts or ends, when a daily limit passes a threshold, at each block's
// reset, at midnight, and when an emergency relief ends.
// It applies and lifts the shields even while Arc Lock itself is closed. Before the first unlock after a restart the
// saved state can't be read (it loads as never set up, see ArcState.isSetUp): then every shield and monitor stays as
// it is, and the next callback or opening Arc Lock catches up.
import DeviceActivity
import Foundation
import ManagedSettings

final class ActivityMonitor: DeviceActivityMonitor {
    /// One callback at a time: iOS can deliver two at once (Brave reports use in batches), and each reads the state,
    /// marks and shields and writes them back, so run together one could undo the other (a used-up limit lifted).
    private static let serial = NSLock()

    override func intervalDidStart(for activity: DeviceActivityName) {
        Self.serial.lock()
        defer { Self.serial.unlock() }
        super.intervalDidStart(for: activity)
        Diag.log("start \(activity.rawValue)")
        // An emergency relief's start: the app has just lifted the shields itself. A read this soon after its write
        // could still find the relief off and shield again, so this one is left alone.
        if activity == Names.relief { return }
        let (state, changed) = Engine.housekeep()
        guard state.isSetUp else { return }
        // The daily monitor, and a block's own reset (its interval start), register again what changed for the new
        // period: a change applied at the reset, or a limit that counted from registration only because its reset time
        // had just changed and now counts whole days again (Registration.serves).
        if activity == Names.daily || Names.ruleID(activity) != nil || changed { Monitoring.sync(state) }
        Monitoring.finishBreaks(state)
        Engine.reconcile(state)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        Self.serial.lock()
        defer { Self.serial.unlock() }
        super.intervalDidEnd(for: activity)
        Diag.log("end \(activity.rawValue)")
        var (state, _) = Engine.housekeep()
        guard state.isSetUp else {
            // An emergency relief ended before the first unlock after a restart: nothing can be read, so its shields
            // can't come back yet. Its monitor looks again in 15 minutes.
            if activity == Names.relief, !StateStore.isSaved { Monitoring.retryReliefEnd() }
            return
        }
        var skip = Set<UUID>()
        if let id = Names.ruleID(activity), let rule = state.rules.first(where: { $0.id == id }), rule.plan.kind == .schedule {
            // The window is over — lift it now even if this callback came a moment early. An end while the window
            // still has more than a few minutes to run belongs to an older interval (iOS can send one when the block's
            // monitor is registered again, as after an edit or new app tokens): then reconcile decides, from the rules.
            let left = Engine.status(rule, now: Date()).blockingUntil?.timeIntervalSinceNow ?? 0
            if left <= 5 * 60 {
                if let store = Engine.store(for: id, in: state) { Shielding.clear(store) }
                skip.insert(id)
            } else {
                Diag.log("  → still runs \(Int(left / 60)) min: an older interval's end, left to reconcile")
            }
        }
        // The emergency relief's 30 minutes are over: its blocks come back now, even if this callback came a moment
        // early. An end with more than a few minutes still to run belongs to an older interval: reconcile decides.
        var reliefOver = false
        if activity == Names.relief, let until = Relief.until {
            let left = until.timeIntervalSinceNow
            if left <= 5 * 60 {
                Relief.close()
                reliefOver = true
                DeviceActivityCenter().stopMonitoring([Names.relief])     // its job is done: free the activity
                Diag.log("  → relief over")
            } else {
                Diag.log("  → relief still runs \(Int(left / 60)) min: an older interval's end, left to reconcile")
            }
        }
        // A time-out's break is over: lift it and start counting toward the next one. Then look again at what was
        // waiting for it to end (deletion protection may switch off once a strict break is over).
        if Monitoring.finishBreaks(state, slack: Names.breakRuleID(activity) != nil ? Engine.edge : 0) {
            let (fresh, changed) = Engine.housekeep()
            if changed { Monitoring.sync(fresh) }
            state = fresh
        }
        // A Block-now end is left to reconcile: it only lifts the session that is really over, never a newer one.
        Engine.reconcile(state, skip: skip)
        if reliefOver, Engine.anythingBlocking(StateStore.load()) {
            Notify.post(id: "relief.end", title: L("Emergency relief is over"), body: L("Your blocks are back on."))
        }
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        Self.serial.lock()
        defer { Self.serial.unlock() }
        super.eventDidReachThreshold(event, activity: activity)
        Diag.log("threshold \(event.rawValue) in \(activity.rawValue)")
        let (state, changed) = Engine.housekeep()
        // an unreadable state has no rules: this block would look deleted and its monitor be stopped
        guard state.isSetUp else { return }
        if changed { Monitoring.sync(state) }
        let now = Date()
        guard let id = Names.ruleID(activity) else { return }
        guard let rule = state.rules.first(where: { $0.id == id }), Engine.counts(rule, now: now) else {
            // deleted or switched off by a change that took effect at midnight
            Diag.log("  → not counting now")
            if !state.rules.contains(where: { $0.id == id }) { DeviceActivityCenter().stopMonitoring([activity]) }
            Engine.reconcile(state)
            return
        }
        // Registered for a different version of the rule (a change applied at its reset, or by an older version of
        // Arc Lock): these thresholds don't mean what they say — re-register, don't block.
        guard let registered = Monitoring.registration(id), registered.serves(Monitoring.plan(for: rule, now: now).registration, now: now),
              let tenth = Names.tenth(of: event), let minutes = registered.thresholds[event.rawValue] else {
            Diag.log("  → registered for a different version: re-sync")
            Monitoring.sync(state, now: now)
            Engine.reconcile(state)
            return
        }
        // iOS sometimes reports a threshold early (right after registering, or twice). Time used can't outrun the
        // clock, so a threshold that couldn't have been reached yet is ignored: since the reset for a daily limit
        // that counts its earlier use, since registering otherwise (a time-out, a limit just given a new reset time).
        // iOS won't send that event again this period, so the monitor is registered again and counts afresh.
        let since = Monitoring.countingSince(id, resetAt: rule.plan.resetAt, now: now)
        guard Plausibility.thresholdIsReal(minutes: minutes, countingSince: since, now: now) else {
            Diag.log("  → too early (\(minutes) min since \(since)): re-arm")
            if tenth >= 10 { Monitoring.rearm(rule, state: state, now: now) }
            return
        }
        if rule.plan.kind == .timeout {
            let onBreak = (Breaks.until(id) ?? .distantPast) > now
            guard tenth >= 10 else {
                // the way through this stretch of use: kept if the time-out is registered again before its break
                // (an app added, fresh app tokens), so that doesn't hand out a fresh stretch (Monitoring.credit)
                if !onBreak {
                    Marks.raise(id, to: tenth, now: now, period: Period.start(containing: now, resetAt: rule.plan.resetAt, calendar: .current))
                }
                Diag.log("  → time-out at tenth \(tenth)")
                return
            }
            guard !onBreak else { Diag.log("  → already on a break"); return }
            Diag.log("  → break for \(rule.plan.breakMinutes) min")
            Monitoring.startBreak(rule, now: now)
            let back = now.addingTimeInterval(TimeInterval(rule.plan.breakMinutes * 60))
            // Strict lock is off but this time-out still keeps it until its reset: a break that starts now runs to
            // its end, strict, even past the reset
            let current = StateStore.load()
            if !current.strictLock, let held = current.strictUntil[id.uuidString], held > now, held < back {
                _ = StateStore.update { _ = $0.holdThroughBreak(id, until: back, now: now) }
            }
            Notify.post(id: "break.\(id)", title: rule.plan.displayName,
                        body: L("Time for a %@ break. Back at %@.", minutesLabel(rule.plan.breakMinutes), Fmt.time(back)))
            Engine.reconcile(StateStore.load(), now: now)
            return
        }
        Diag.log("  → limit at tenth \(tenth)")
        Marks.raise(id, to: tenth, now: now, period: Period.start(containing: now, resetAt: rule.plan.resetAt, calendar: .current))
        if tenth >= 10 {
            // during an emergency relief this shields nothing yet: the limit locks when the relief ends
            if let store = Engine.store(for: id, in: state) {
                Shielding.apply(rule.selection, domains: rule.plan.domains, to: store, hold: state.isStrict(rule, now: now), now: now)
            }
            let reset = Period.end(after: now, resetAt: rule.plan.resetAt, calendar: .current)
            if state.reliefEnabled, Relief.isActive(now: now), let back = Relief.until, back < reset {
                Notify.post(id: "reached.\(id)", title: rule.plan.displayName,
                            body: L("This limit is used up. It locks when emergency relief ends, at %@.", Fmt.time(back)))
            } else {
                Notify.post(id: "reached.\(id)", title: rule.plan.displayName, body: L("This limit is used up. It unlocks at %@.", Fmt.moment(reset)))
            }
        }
        Engine.reconcile(state, now: now)
    }

    override func eventWillReachThresholdWarning(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventWillReachThresholdWarning(event, activity: activity)
        Diag.log("warning \(event.rawValue) in \(activity.rawValue)")
        let now = Date()
        guard event == Names.limitEvent, let id = Names.ruleID(activity),
              let rule = StateStore.load().rules.first(where: { $0.id == id }), Engine.counts(rule, now: now),
              // a daily limit saved (or changed) when its time was nearly or fully used: iOS warns at once, for use
              // from before; "5 minutes left" would be wrong — its lock, if it's used up, follows at once
              rule.plan.kind != .limit || Monitoring.registeredAt(id).map({ now.timeIntervalSince($0) >= 60 }) ?? true,
              !(rule.plan.kind == .limit && Engine.status(rule, now: now).isBlocking),
              let minutes = Monitoring.registration(id)?.thresholds[event.rawValue],
              // the warning comes 5 minutes before the limit, so the same clock check applies
              Plausibility.thresholdIsReal(minutes: max(1, minutes - (rule.plan.kind == .timeout ? 1 : 5)),
                                           countingSince: Monitoring.countingSince(id, resetAt: rule.plan.resetAt, now: now), now: now)
        else { return }
        if rule.plan.kind == .timeout {
            Notify.post(id: "warn.\(id)", title: rule.plan.displayName,
                        body: L("1 minute until a %@ break.", minutesLabel(rule.plan.breakMinutes)))
        } else {
            Notify.post(id: "warn.\(id)", title: rule.plan.displayName, body: L("5 minutes left."))
        }
    }

    override func intervalWillStartWarning(for activity: DeviceActivityName) {
        super.intervalWillStartWarning(for: activity)
        guard let id = Names.ruleID(activity), let rule = StateStore.load().rules.first(where: { $0.id == id }),
              rule.plan.kind == .schedule, rule.plan.isOn,
              let next = ScheduleMath.nextWindow(after: Date(), plan: rule.plan, calendar: .current),
              next.start.timeIntervalSinceNow < 10 * 60 else { return }
        Notify.post(id: "soon.\(id)", title: rule.plan.displayName, body: L("Starts in 5 minutes, at %@.", Fmt.time(next.start)))
    }
}

/// "10 min", "1 hr", "1 hr 30 min" in the reader's language.
func minutesLabel(_ minutes: Int) -> String {
    let f = DateComponentsFormatter()
    f.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
    f.unitsStyle = .short
    f.zeroFormattingBehavior = .dropAll
    return f.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) min"
}
