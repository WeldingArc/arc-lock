// Shows how much of a block's time is used today, to the minute, inside Arc Lock's Home screen. iOS hands Screen
// Time minutes only to this extension and keeps them here: Arc Lock itself never sees the numbers, it only shows
// this view. (Daily limits still lock on iOS's own count; this is what the user reads.)
import DeviceActivity
import ExtensionKit
import Foundation
import SwiftUI

@main
struct UsageReportExtension: DeviceActivityReportExtension {
    // One scene per store slot (Names.slotCount): the app asks for "slot.N" for the block that holds slot N.
    var body: some DeviceActivityReportScene {
        UsageScene(slot: 0)
        UsageScene(slot: 1)
        UsageScene(slot: 2)
        UsageScene(slot: 3)
        UsageScene(slot: 4)
        UsageScene(slot: 5)
        UsageScene(slot: 6)
        UsageScene(slot: 7)
        UsageScene(slot: 8)
        UsageScene(slot: 9)
        UsageScene(slot: 10)
        UsageScene(slot: 11)
        UsageScene(slot: 12)
        UsageScene(slot: 13)
        UsageScene(slot: 14)
        UsageScene(slot: 15)
        UsageScene(slot: 16)
        UsageScene(slot: 17)
    }
}

struct UsageScene: DeviceActivityReportScene {
    let context: DeviceActivityReport.Context
    let slot: Int
    let content: (UsageSummary) -> UsageView = { UsageView(usage: $0) }

    init(slot: Int) {
        self.slot = slot
        context = .init(UsageSummary.context(slot: slot))
    }

    func makeConfiguration(representing data: DeviceActivityResults<DeviceActivityData>) async -> UsageSummary {
        let now = Date(), calendar = Calendar.current
        let midnight = calendar.startOfDay(for: now)
        // The block itself comes from the shared state; if it can't be read, the line still shows today's minutes.
        let state = StateStore.load()
        let rule = state.rules.first { state.slot(of: $0.id) == slot }
        let limit = rule.flatMap { $0.plan.kind == .limit ? $0 : nil }
        // The block's own day starts at its reset time (midnight by default). A daily limit counts from then, or from
        // when it was created or changed (plus the time carried over by that change): the same count that locks it.
        let periodStart = rule.map { Period.start(containing: now, resetAt: $0.plan.resetAt, calendar: calendar) } ?? midnight
        let since = limit.map { Monitoring.countingSince($0.id, resetAt: $0.plan.resetAt, now: now, calendar: calendar) } ?? periodStart
        var seconds: TimeInterval = 0
        for await day in data {
            for await hour in day.activitySegments {
                let span = hour.dateInterval
                guard span.end > since else { continue }
                let used = await Self.seconds(in: hour)
                if span.start < since, span.duration > 0 {
                    seconds += used * span.end.timeIntervalSince(since) / span.duration   // the hour the count began
                } else {
                    seconds += used
                }
            }
        }
        var minutes = Int(seconds / 60)
        if let limit { minutes += Credits.today(limit.id, period: periodStart) }
        // "since 4:00 AM" when the count began later than midnight (a reset time, or a change today)
        let shownSince = since > periodStart ? since : (rule.map { $0.plan.resetAt != .midnight } == true ? periodStart : nil)
        return UsageSummary(minutes: minutes, limit: limit?.plan.limitMinutes, since: shownSince)
    }

    /// Everything the filter let through: the block's apps, the apps in its categories, and its websites.
    private static func seconds(in segment: DeviceActivityData.ActivitySegment) async -> TimeInterval {
        var total: TimeInterval = 0
        for await category in segment.categories {
            for await app in category.applications { total += app.totalActivityDuration }
            for await site in category.webDomains { total += site.totalActivityDuration }
        }
        return total
    }
}
