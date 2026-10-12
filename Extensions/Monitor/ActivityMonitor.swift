// Runs in the background when a schedule starts or ends, when a daily limit passes a threshold, and at midnight.
// It applies and lifts the shields even while Arc Lock itself is closed.
import DeviceActivity
import Foundation
import ManagedSettings

final class ActivityMonitor: DeviceActivityMonitor {
    override func intervalDidStart(for activity: DeviceActivityName) {
        super.intervalDidStart(for: activity)
        let (state, changed) = Engine.housekeep()
        // The daily monitor also re-registers limits whose thresholds were only meant for yesterday.
        if activity == Names.daily || changed { Monitoring.sync(state) }
        Engine.reconcile(state)
    }

    override func intervalDidEnd(for activity: DeviceActivityName) {
        super.intervalDidEnd(for: activity)
        let (state, _) = Engine.housekeep()
        var skip = Set<UUID>()
        if let id = Names.ruleID(activity), let rule = state.rules.first(where: { $0.id == id }), rule.plan.kind == .schedule {
            // The window is over — lift it now even if this callback came a moment early.
            if let store = Engine.store(for: id, in: state) { Shielding.clear(store) }
            skip.insert(id)
        }
        // A Block-now end is left to reconcile: it only lifts the session that is really over, never a newer one.
        Engine.reconcile(state, skip: skip)
    }

    override func eventDidReachThreshold(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventDidReachThreshold(event, activity: activity)
        let (state, changed) = Engine.housekeep()
        if changed { Monitoring.sync(state) }
        let now = Date()
        guard let id = Names.ruleID(activity) else { return }
        guard let rule = state.rules.first(where: { $0.id == id }), Engine.counts(rule, now: now) else {
            // deleted or switched off by a change that took effect at midnight
            if !state.rules.contains(where: { $0.id == id }) { DeviceActivityCenter().stopMonitoring([activity]) }
            Engine.reconcile(state)
            return
        }
        // Registered for a different version of the rule (a change applied at midnight, or yesterday's credit):
        // these thresholds don't mean what they say — re-register, don't block.
        guard let registered = Monitoring.registration(id), registered == Monitoring.plan(for: rule, now: now).registration,
              let tenth = Names.tenth(of: event), let minutes = registered.thresholds[event.rawValue] else {
            Monitoring.sync(state, now: now)
            Engine.reconcile(state)
            return
        }
        // iOS sometimes reports a threshold early (right after registering, or twice). Time used can't outrun the
        // clock, so a threshold that couldn't have been reached yet is ignored. iOS won't send that event again
        // today, so a too-early limit restarts its count from what today's marks prove.
        guard Plausibility.thresholdIsReal(minutes: minutes, countingSince: Monitoring.countingSince(id, now: now), now: now) else {
            if tenth >= 10 { Monitoring.rearm(rule, state: state, now: now) }
            return
        }
        Marks.raise(id, to: tenth, now: now)
        if tenth >= 10 {
            if let store = Engine.store(for: id, in: state) {
                Shielding.apply(rule.selection, domains: rule.plan.domains, to: store)
            }
            Notify.post(id: "reached.\(id)", title: rule.plan.name, body: L("Today's limit is used up. It unlocks at midnight."))
        }
        Engine.reconcile(state, now: now)
    }

    override func eventWillReachThresholdWarning(_ event: DeviceActivityEvent.Name, activity: DeviceActivityName) {
        super.eventWillReachThresholdWarning(event, activity: activity)
        let now = Date()
        guard event == Names.limitEvent, let id = Names.ruleID(activity),
              let rule = StateStore.load().rules.first(where: { $0.id == id }), Engine.counts(rule, now: now),
              let minutes = Monitoring.registration(id)?.thresholds[event.rawValue],
              // the warning comes 5 minutes before the limit, so the same clock check applies
              Plausibility.thresholdIsReal(minutes: max(1, minutes - 5), countingSince: Monitoring.countingSince(id, now: now), now: now)
        else { return }
        Notify.post(id: "warn.\(id)", title: rule.plan.name, body: L("5 minutes left for today."))
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
