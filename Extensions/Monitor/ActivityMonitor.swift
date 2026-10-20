// Runs in the background when a schedule starts or ends, when a daily limit passes a threshold, and at midnight.
// It applies and lifts the shields even while Arc Lock itself is closed.
import DeviceActivity
import Foundation
import ManagedSettings

final class ActivityMonitor: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        Diag.log("start \(activity.rawValue)")
        let (state, changed) = Engine.housekeep()
        // The daily monitor, and a block's own reset (its interval start), re-register limits whose thresholds were
        // only meant for the period that just ended.
        if activity == Names.daily || Names.ruleID(activity) != nil || changed { Monitoring.sync(state) }
        Monitoring.finishBreaks(state)
        Engine.reconcile(state)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        Diag.log("end \(activity.rawValue)")
        var (state, _) = Engine.housekeep()
        var skip = Set<UUID>()
        if let id = Names.ruleID(activity), let rule = state.rules.first(where: { $0.id == id }), rule.plan.kind == .schedule {
            // The window is over — lift it now even if this callback came a moment early.
            if let store = Engine.store(for: id, in: state) { Shielding.clear(store) }
            skip.insert(id)
        }
        // A time-out's break is over: lift it and start counting toward the next one. Then look again at what was
        // waiting for it to end (Strict lock switching off never happens under a running strict break).
        if Monitoring.finishBreaks(state, slack: Names.breakRuleID(activity) != nil ? Engine.edge : 0) {
            let (fresh, changed) = Engine.housekeep()
            if changed { Monitoring.sync(fresh) }
            state = fresh
        }
        // A Block-now end is left to reconcile: it only lifts the session that is really over, never a newer one.
        Engine.reconcile(state, skip: skip)
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        Diag.log("threshold \(event.rawValue) in \(activity.rawValue)")
        let (state, changed) = Engine.housekeep()
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
        // Registered for a different version of the rule (a change applied at midnight, or yesterday's credit):
        // these thresholds don't mean what they say — re-register, don't block.
        guard let registered = Monitoring.registration(id), registered == Monitoring.plan(for: rule, now: now).registration,
              let tenth = Names.tenth(of: event), let minutes = registered.thresholds[event.rawValue] else {
            Diag.log("  → registered for a different version: re-sync")
            Monitoring.sync(state, now: now)
            Engine.reconcile(state)
            return
        }
        // iOS sometimes reports a threshold early (right after registering, or twice). Time used can't outrun the
        // clock, so a threshold that couldn't have been reached yet is ignored. iOS won't send that event again
        // today, so a too-early limit restarts its count from what today's marks prove.
        let since = Monitoring.countingSince(id, resetAt: rule.plan.resetAt, now: now)
        guard Plausibility.thresholdIsReal(minutes: minutes, countingSince: since, now: now) else {
            Diag.log("  → too early (\(minutes) min since \(since)): re-arm")
            if tenth >= 10 { Monitoring.rearm(rule, state: state, now: now) }
            return
        }
        if rule.plan.kind == .timeout {
            guard tenth >= 10, (Breaks.until(id) ?? .distantPast) <= now else { Diag.log("  → already on a break"); return }
            Diag.log("  → break for \(rule.plan.breakMinutes) min")
            Monitoring.startBreak(rule, now: now)
            let back = now.addingTimeInterval(TimeInterval(rule.plan.breakMinutes * 60))
            Notify.post(id: "break.\(id)", title: rule.plan.name,
                        body: L("Time for a %@ break. Back at %@.", minutesLabel(rule.plan.breakMinutes), Fmt.time(back)))
            Engine.reconcile(StateStore.load(), now: now)
            return
        }
        Diag.log("  → limit at tenth \(tenth)")
        Marks.raise(id, to: tenth, now: now, period: Period.start(containing: now, resetAt: rule.plan.resetAt, calendar: .current))
        if tenth >= 10 {
            if let store = Engine.store(for: id, in: state) {
                Shielding.apply(rule.selection, domains: rule.plan.domains, to: store, hold: state.isStrict(rule.plan, now: now))
            }
            let reset = Period.end(after: now, resetAt: rule.plan.resetAt, calendar: .current)
            Notify.post(id: "reached.\(id)", title: rule.plan.name, body: L("This limit is used up. It unlocks at %@.", Fmt.moment(reset)))
        }
        Engine.reconcile(state, now: now)
    }

    override func eventWillReachThresholdWarning(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventWillReachThresholdWarning(event, activity: activity)
        Diag.log("warning \(event.rawValue) in \(activity.rawValue)")
        let now = Date()
        guard event == Names.limitEvent, let id = Names.ruleID(activity),
              let rule = StateStore.load().rules.first(where: { $0.id == id }), Engine.counts(rule, now: now),
              let minutes = Monitoring.registration(id)?.thresholds[event.rawValue],
              // the warning comes 5 minutes before the limit, so the same clock check applies
              Plausibility.thresholdIsReal(minutes: max(1, minutes - (rule.plan.kind == .timeout ? 1 : 5)),
                                           countingSince: Monitoring.countingSince(id, resetAt: rule.plan.resetAt, now: now), now: now)
        else { return }
        if rule.plan.kind == .timeout {
            Notify.post(id: "warn.\(id)", title: rule.plan.name,
                        body: L("1 minute until a %@ break.", minutesLabel(rule.plan.breakMinutes)))
        } else {
            Notify.post(id: "warn.\(id)", title: rule.plan.name, body: L("5 minutes left."))
        }
    }

    override func intervalWillStartWarning(for activity: DeviceActivityName) {
        super.intervalWillStartWarning(for: activity)
        guard let id = Names.ruleID(activity), let rule = StateStore.load().rules.first(where: { $0.id == id }),
              rule.plan.kind == .schedule, rule.plan.isOn,
              let next = ScheduleMath.nextWindow(after: Date(), plan: rule.plan, calendar: .current),
              next.start.timeIntervalSinceNow < 10 * 60 else { return }
        Notify.post(id: "soon.\(id)", title: rule.plan.name, body: L("Starts in 5 minutes, at %@.", Fmt.time(next.start)))
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
