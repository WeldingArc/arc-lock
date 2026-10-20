// Unit tests for Core/ArcCore.swift that run on the Mac (no simulator):
//   swiftc -parse-as-library Core/ArcCore.swift Tests/CoreTests.swift -o build/coretests && build/coretests
import Foundation

var failures = 0
var checks = 0
func check(_ ok: Bool, _ what: String, file: String = #file, line: Int = #line) {
    checks += 1
    if !ok { failures += 1; print("FAIL line \(line): \(what)") }
}

func calendar(_ tz: String) -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: tz)!
    return c
}
func date(_ s: String, _ cal: Calendar) -> Date {
    // "2026-10-12 09:30" in the calendar's zone
    let f = DateFormatter()
    f.calendar = cal; f.timeZone = cal.timeZone; f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: s)!
}

@main
struct CoreTests {
    static func main() {
        let seoul = calendar("Asia/Seoul")
        // 2026-10-12 is a Monday (weekday 2).
        check(seoul.component(.weekday, from: date("2026-10-12 12:00", seoul)) == 2, "fixture: Oct 12 2026 is Monday")

        // Lengths
        check(ScheduleMath.length(TimeOfDay(9, 0), TimeOfDay(17, 0)) == 480, "9–17 is 8 h")
        check(ScheduleMath.length(TimeOfDay(22, 0), TimeOfDay(7, 0)) == 540, "22–7 is 9 h overnight")
        check(ScheduleMath.length(TimeOfDay(8, 0), TimeOfDay(8, 0)) == 1440, "same start/end = 24 h")

        // Weekday schedule 9–17 Mon–Fri
        let work = RulePlan(name: "Study", kind: .schedule, start: TimeOfDay(9, 0), end: TimeOfDay(17, 0), days: [2, 3, 4, 5, 6])
        let monNoon = date("2026-10-12 12:00", seoul)
        check(Status.of(work, now: monNoon, reachedAt: nil, calendar: seoul) == .running(until: date("2026-10-12 17:00", seoul)), "Mon noon runs until 17:00")
        check(Status.of(work, now: date("2026-10-12 17:00", seoul), reachedAt: nil, calendar: seoul) == .waiting(next: date("2026-10-13 09:00", seoul)), "17:00 sharp has ended; next Tue 9:00")
        check(Status.of(work, now: date("2026-10-12 08:59", seoul), reachedAt: nil, calendar: seoul) == .waiting(next: date("2026-10-12 09:00", seoul)), "8:59 waits for 9:00")
        check(Status.of(work, now: date("2026-10-17 12:00", seoul), reachedAt: nil, calendar: seoul) == .waiting(next: date("2026-10-19 09:00", seoul)), "Saturday off; next Monday")
        var off = work; off.isOn = false
        check(Status.of(off, now: monNoon, reachedAt: nil, calendar: seoul) == .off, "switched off")

        // Overnight 22–07 on Fri only: belongs to Friday, runs into Saturday morning
        let night = RulePlan(name: "Sleep", kind: .schedule, start: TimeOfDay(22, 0), end: TimeOfDay(7, 0), days: [6])
        check(Status.of(night, now: date("2026-10-17 06:30", seoul), reachedAt: nil, calendar: seoul) == .running(until: date("2026-10-17 07:00", seoul)), "Sat 6:30 still in Friday's night")
        check(Status.of(night, now: date("2026-10-16 23:00", seoul), reachedAt: nil, calendar: seoul) == .running(until: date("2026-10-17 07:00", seoul)), "Fri 23:00 runs until Sat 7:00")
        check(Status.of(night, now: date("2026-10-18 06:30", seoul), reachedAt: nil, calendar: seoul) == .waiting(next: date("2026-10-23 22:00", seoul)), "Sun 6:30 not in a window (Sat not selected)")
        check(Status.of(night, now: date("2026-10-16 21:59", seoul), reachedAt: nil, calendar: seoul) == .waiting(next: date("2026-10-16 22:00", seoul)), "Fri 21:59 waits")

        // Daylight saving (New York): spring forward 2026-03-08 02:00 → 03:00, fall back 2026-11-01 02:00 → 01:00
        let ny = calendar("America/New_York")
        let nightNY = RulePlan(name: "Sleep", kind: .schedule, start: TimeOfDay(22, 0), end: TimeOfDay(7, 0), days: Set(1...7))
        let springWin = ScheduleMath.window(startingOn: date("2026-03-07 12:00", ny), plan: nightNY, calendar: ny)!
        check(springWin.end == date("2026-03-08 07:00", ny), "spring-forward night ends 07:00 wall clock")
        check(springWin.duration == 8 * 3600, "spring-forward night is 8 real hours")
        let fallWin = ScheduleMath.window(startingOn: date("2026-10-31 12:00", ny), plan: nightNY, calendar: ny)!
        check(fallWin.duration == 10 * 3600, "fall-back night is 10 real hours")

        // Daily limits
        let social = RulePlan(name: "Social", kind: .limit, days: [2, 3, 4, 5, 6], limitMinutes: 30)
        check(Status.of(social, now: monNoon, reachedAt: nil, calendar: seoul) == .counting, "limit counting on Monday")
        check(Status.of(social, now: monNoon, reachedAt: date("2026-10-12 10:00", seoul), calendar: seoul) == .reached(until: date("2026-10-13 00:00", seoul)), "reached today → until midnight")
        check(Status.of(social, now: monNoon, reachedAt: date("2026-10-11 23:50", seoul), calendar: seoul) == .counting, "reached yesterday → counting again")
        check(Status.of(social, now: date("2026-10-18 12:00", seoul), reachedAt: nil, calendar: seoul) == .resting, "Sunday not selected → resting")

        // Who may edit what
        let runUntil = date("2026-10-12 17:00", seoul)
        check(Policy.access(status: .running(until: runUntil), lockInUntil: nil, now: monNoon, calendar: seoul) == .locked(until: runUntil, reason: .running), "running → locked")
        check(Policy.access(status: .counting, lockInUntil: nil, now: monNoon, calendar: seoul) == .stricterOnly(loosenFrom: date("2026-10-13 00:00", seoul)), "counting → stricter only until midnight")
        check(Policy.access(status: .waiting(next: nil), lockInUntil: nil, now: monNoon, calendar: seoul) == .free, "waiting → free")
        let lockIn = date("2026-10-20 12:00", seoul)
        check(Policy.access(status: .waiting(next: nil), lockInUntil: lockIn, now: monNoon, calendar: seoul) == .locked(until: lockIn, reason: .lockIn), "lock-in → locked")
        check(Policy.access(status: .running(until: runUntil), lockInUntil: date("2026-10-12 13:00", seoul), now: monNoon, calendar: seoul) == .locked(until: runUntil, reason: .running), "later of running/lock-in wins")
        check(Policy.access(status: .counting, lockInUntil: date("2026-10-12 11:00", seoul), now: monNoon, calendar: seoul) == .stricterOnly(loosenFrom: date("2026-10-13 00:00", seoul)), "expired lock-in ignored")

        // Stricter vs looser
        var more = social; more.limitMinutes = 60
        check(Change.direction(from: social, to: more) == .looser, "raising a limit is looser")
        var less = social; less.limitMinutes = 15
        check(Change.direction(from: social, to: less) == .stricter, "lowering a limit is stricter")
        var renamed = social; renamed.name = "Feeds"
        check(Change.direction(from: social, to: renamed) == .same, "renaming changes nothing")
        var fewerDays = social; fewerDays.days = [2, 3]
        check(Change.direction(from: social, to: fewerDays) == .looser, "fewer days is looser")
        var moreDays = social; moreDays.days = Set(1...7)
        check(Change.direction(from: social, to: moreDays) == .stricter, "more days is stricter")
        var turnedOff = social; turnedOff.isOn = false
        check(Change.direction(from: social, to: turnedOff) == .looser, "switching off is looser")
        check(Change.direction(from: turnedOff, to: social) == .stricter, "switching on is stricter")
        check(Change.direction(from: social, to: renamed, selectionLost: true) == .looser, "dropping an app is looser")
        check(Change.direction(from: social, to: renamed, selectionGained: true) == .stricter, "adding an app is stricter")
        check(Change.direction(from: social, to: less, selectionLost: true) == .looser, "mixed change counts as looser")
        var wider = work; wider.start = TimeOfDay(8, 0); wider.end = TimeOfDay(18, 0)
        check(Change.direction(from: work, to: wider) == .stricter, "wider window is stricter")
        var shorter = work; shorter.end = TimeOfDay(12, 0)
        check(Change.direction(from: work, to: shorter) == .looser, "shorter window is looser")
        var moved = work; moved.start = TimeOfDay(10, 0); moved.end = TimeOfDay(18, 0)
        check(Change.direction(from: work, to: moved) == .looser, "moved window is looser")
        var nightWider = night; nightWider.start = TimeOfDay(21, 0); nightWider.end = TimeOfDay(8, 0)
        check(Change.direction(from: night, to: nightWider) == .stricter, "wider overnight window is stricter")
        var asLimit = work; asLimit.kind = .limit
        check(Change.direction(from: work, to: asLimit) == .looser, "changing the kind is looser")
        var withSite = work; withSite.domains = ["youtube.com"]
        check(Change.direction(from: work, to: withSite) == .stricter, "adding a website is stricter")
        check(Change.direction(from: withSite, to: work) == .looser, "removing a website is looser")

        // Typed websites
        check(Domains.normalize("https://www.YouTube.com/watch?v=1") == "youtube.com", "url → domain")
        check(Domains.normalize("  m.facebook.com ") == "m.facebook.com", "subdomain kept")
        check(Domains.normalize("reddit.com:443/r/x") == "reddit.com", "port stripped")
        check(Domains.normalize("naver.com.") == "naver.com", "trailing dot")
        check(Domains.normalize("youtube") == nil, "no dot → nil")
        check(Domains.normalize("you tube.com") == nil, "space → nil")
        check(Domains.normalize("-bad.com") == nil, "leading hyphen → nil")
        check(Domains.normalize("1.2.3.4") == nil, "IP address → nil")
        check(Domains.normalize("네이버.한국") == "네이버.한국", "IDN kept")

        // Pending changes
        var rules = [
            RuleRecord(plan: social, selection: "apps-A",
                       pending: PendingChange(plan: more, selection: nil, effectiveAt: date("2026-10-13 00:00", seoul))),
            RuleRecord(plan: work, selection: "apps-B",
                       pending: PendingChange(plan: nil, selection: nil, effectiveAt: date("2026-10-13 00:00", seoul))),
            RuleRecord(plan: night, selection: "apps-C"),
        ]
        let before = rules
        check(Pending.applyDue(&rules, now: date("2026-10-12 23:59", seoul)).isEmpty && rules == before, "nothing due before midnight")
        let changed = Pending.applyDue(&rules, now: date("2026-10-13 00:00", seoul))
        check(changed.count == 2, "two changes applied at midnight")
        check(rules.count == 2, "deleted rule removed")
        check(rules[0].plan.limitMinutes == 60 && rules[0].pending == nil && rules[0].selection == "apps-A", "edit applied, selection kept")
        check(rules[1].plan.name == "Sleep", "untouched rule kept")

        // Validation
        check(Validate.problems(work, appCount: 3, hasSelection: true).isEmpty, "valid schedule")
        var tiny = work; tiny.end = TimeOfDay(9, 10)
        check(Validate.problems(tiny, appCount: 1, hasSelection: true).contains(.windowTooShort), "10-minute window rejected")
        var noName = work; noName.name = "  "
        check(Validate.problems(noName, appCount: 1, hasSelection: true).contains(.noName), "blank name rejected")
        check(Validate.problems(work, appCount: 0, hasSelection: false).contains(.nothingChosen), "nothing chosen rejected")
        check(!Validate.problems(withSite, appCount: 0, hasSelection: false).contains(.nothingChosen), "a typed website alone is enough for a schedule")
        var siteLimit = social; siteLimit.domains = ["youtube.com"]
        check(Validate.problems(siteLimit, appCount: 0, hasSelection: false).contains(.nothingChosen), "a limit needs apps (typed sites can't be measured)")
        var big = social; big.limitMinutes = 500
        check(Validate.problems(big, appCount: 1, hasSelection: true).contains(.limitOutOfRange), "limit over 8 h rejected")
        check(Validate.problems(social, appCount: 51, hasSelection: true).contains(.tooManyApps), "51 apps rejected")
        var badSite = work; badSite.domains = ["YouTube.com"]
        check(Validate.problems(badSite, appCount: 1, hasSelection: true).contains(.badDomain("YouTube.com")), "un-normalized domain flagged")

        // Store slots: bounded pool, stable, reused
        var slots = Slots.assign([:], ruleIDs: ["a", "b", "c"], count: 3)
        check(slots == ["a": 0, "b": 1, "c": 2], "slots handed out lowest first")
        slots = Slots.assign(slots, ruleIDs: ["a", "c", "d"], count: 3)
        check(slots == ["a": 0, "c": 2, "d": 1], "deleted rule's slot is reused, others stay put")
        slots = Slots.assign(slots, ruleIDs: ["a", "c", "d", "e"], count: 3)
        check(slots["e"] == nil && slots.count == 3, "no slot beyond the pool")
        check(Slots.assign(["x": 7], ruleIDs: ["x"], count: 3) == ["x": 0], "out-of-range slot reassigned")

        // Plausibility of usage thresholds (iOS's early-fire bug must never cause a false lock)
        let reg = date("2026-10-12 15:00", seoul)
        check(!Plausibility.thresholdIsReal(minutes: 30, countingSince: reg, now: reg.addingTimeInterval(2)), "fires 2 s after registering → ignored")
        check(!Plausibility.thresholdIsReal(minutes: 30, countingSince: reg, now: reg.addingTimeInterval(29 * 60)), "30-min limit after 29 min → impossible")
        check(Plausibility.thresholdIsReal(minutes: 30, countingSince: reg, now: reg.addingTimeInterval(30 * 60)), "30-min limit after 30 min → real")
        check(Plausibility.thresholdIsReal(minutes: 30, countingSince: reg, now: reg.addingTimeInterval(4 * 3600)), "hours later → real")
        check(!Plausibility.thresholdIsReal(minutes: 1, countingSince: reg, now: reg.addingTimeInterval(50)), "even a 1-min threshold needs a minute")
        check(Plausibility.thresholdIsReal(minutes: 1, countingSince: reg, now: reg.addingTimeInterval(61)), "1-min threshold after 61 s → real")

        // Never-ending schedules are refused (a block must leave time to be changed)
        let allDay = RulePlan(name: "All", kind: .schedule, start: TimeOfDay(0, 0), end: TimeOfDay(0, 0), days: Set(1...7))
        check(Validate.problems(allDay, appCount: 1, hasSelection: true).contains(.windowTooLong), "00:00→00:00 (24 h) refused")
        var nearlyAllDay = allDay; nearlyAllDay.start = TimeOfDay(7, 0); nearlyAllDay.end = TimeOfDay(6, 59)
        check(Validate.problems(nearlyAllDay, appCount: 1, hasSelection: true).contains(.windowTooLong), "07:00→06:59 refused")
        var twentyThree = allDay; twentyThree.start = TimeOfDay(7, 0); twentyThree.end = TimeOfDay(6, 0)
        check(Validate.problems(twentyThree, appCount: 1, hasSelection: true).contains(.windowTooLong), "23 h refused (DST could eat the gap)")
        var twentyTwo = allDay; twentyTwo.start = TimeOfDay(7, 0); twentyTwo.end = TimeOfDay(5, 0)
        check(Validate.problems(twentyTwo, appCount: 1, hasSelection: true).isEmpty, "exactly 22 h allowed")
        // ...so every valid every-day schedule is editable at least an hour a day
        var editable = 0
        for m in stride(from: 0, to: 24 * 60, by: 1) {
            let t = date("2026-10-12 00:00", seoul).addingTimeInterval(TimeInterval(m * 60))
            if Policy.access(status: Status.of(twentyTwo, now: t, reachedAt: nil, calendar: seoul), lockInUntil: nil, now: t, calendar: seoul) == .free { editable += 1 }
        }
        check(editable == 120, "a 22-hour every-day schedule is editable 120 minutes a day (got \(editable))")
        // daylight saving: the 22-hour cap still leaves real time on the spring-forward day (New York 2026-03-08)
        var dst = RulePlan(name: "Long", kind: .schedule, start: TimeOfDay(3, 0), end: TimeOfDay(1, 0), days: Set(1...7))
        var free = 0
        var tt = date("2026-03-08 00:00", ny)
        while tt < date("2026-03-09 00:00", ny) {
            if Policy.access(status: Status.of(dst, now: tt, reachedAt: nil, calendar: ny), lockInUntil: nil, now: tt, calendar: ny) == .free { free += 1 }
            tt = tt.addingTimeInterval(60)
        }
        check(free >= 60, "spring-forward day keeps at least an hour editable (got \(free) min)")
        dst.isOn = true

        // Lord Howe Island moves its clocks 30 min at 02:00: a skipped end time must stay on the same day
        let lh = calendar("Australia/Lord_Howe")
        let lhPlan = RulePlan(name: "LH", kind: .schedule, start: TimeOfDay(4, 0), end: TimeOfDay(2, 0), days: Set(1...7))
        if let w = ScheduleMath.window(startingOn: date("2026-10-03 12:00", lh), plan: lhPlan, calendar: lh) {
            check(w.duration <= 23 * 3600, "Lord Howe: a window ending in the skipped half hour stays under a day (\(w.duration / 3600) h)")
        } else { check(false, "Lord Howe window exists") }
        var lhFree = 0
        var lt = date("2026-10-04 00:00", lh)
        while lt < date("2026-10-05 00:00", lh) {
            if Policy.access(status: Status.of(lhPlan, now: lt, reachedAt: nil, calendar: lh), lockInUntil: nil, now: lt, calendar: lh) == .free { lhFree += 1 }
            lt = lt.addingTimeInterval(60)
        }
        check(lhFree >= 60, "Lord Howe spring-forward day keeps at least an hour editable (got \(lhFree) min)")

        // All schedules together must leave a free hour every day (or blocks that include Arc Lock could shut it for good)
        func sched(_ s: (Int, Int), _ e: (Int, Int), _ days: Set<Int> = Set(1...7)) -> RulePlan {
            RulePlan(name: "x", kind: .schedule, start: TimeOfDay(s.0, s.1), end: TimeOfDay(e.0, e.1), days: days)
        }
        check(Coverage.leavesFreeTime([]), "no schedules → free")
        check(Coverage.leavesFreeTime([sched((7, 0), (5, 0))]), "one 22 h schedule → free")
        check(Coverage.leavesFreeTime([sched((7, 0), (5, 0)), sched((8, 0), (6, 0))]), "staggered 22 h pair with a shared free hour → ok")
        check(!Coverage.leavesFreeTime([sched((7, 0), (5, 0)), sched((9, 0), (7, 0))]), "two schedules covering the whole day → refused")
        check(Coverage.leavesFreeTime([sched((23, 0), (7, 0)), sched((9, 0), (17, 0))]), "sleep + work → ok")
        check(Coverage.leavesFreeTime([sched((23, 0), (8, 0)), sched((8, 0), (22, 0))]), "exactly one free hour → ok")
        check(!Coverage.leavesFreeTime([sched((23, 0), (8, 0)), sched((8, 0), (22, 30))]), "only 30 free minutes → refused")
        check(!Coverage.leavesFreeTime([sched((7, 0), (5, 0), [2, 3, 4, 5, 6]), sched((9, 0), (7, 0), [2, 3, 4, 5, 6])]),
              "weekday-only full coverage (5 days shut) → refused")
        var offOne = sched((9, 0), (7, 0)); offOne.isOn = false
        check(Coverage.leavesFreeTime([sched((7, 0), (5, 0)), offOne]), "switched-off schedules don't count")
        check(Coverage.leavesFreeTime([sched((7, 0), (5, 0)), RulePlan(name: "l", kind: .limit, limitMinutes: 30)]), "limits don't count")
        check(Limits.maxApps <= 49 && Limits.maxDomains <= 49, "token caps stay under iOS's 50")

        // A lock-in holds queued changes back until it ends
        var held = [RuleRecord(plan: social, selection: "apps-A",
                               pending: PendingChange(plan: nil, selection: nil, effectiveAt: date("2026-10-13 00:00", seoul)))]
        check(Pending.applyDue(&held, now: date("2026-10-14 09:00", seoul), frozenUntil: date("2026-10-20 00:00", seoul)).isEmpty && held.count == 1,
              "a deletion queued before a lock-in waits for it to end")
        check(Pending.applyDue(&held, now: date("2026-10-20 00:00", seoul), frozenUntil: date("2026-10-20 00:00", seoul)).count == 1 && held.isEmpty,
              "...and applies once the lock-in is over")

        // Limit thresholds: tenths, and today's carried-over use
        let t30 = LimitMath.thresholds(limit: 30)
        check(t30.map(\.tenth) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10] && t30.last!.minutes == 30 && t30.first!.minutes == 3, "30 min → events every 3 min")
        let t5 = LimitMath.thresholds(limit: 5)
        check(Set(t5.map(\.minutes)).count == t5.count && t5.last! == (10, 5) && t5.allSatisfy { $0.minutes >= 1 }, "5 min → no duplicate or zero events")
        let credited = LimitMath.thresholds(limit: 25, credit: 22)
        check(credited.last! == (10, 3) && credited.count == 1, "25-min limit with 22 used → locks after 3 more minutes")
        let over = LimitMath.thresholds(limit: 25, credit: 40)
        check(over.count == 1 && over[0] == (10, 1), "already over → a 1-minute threshold (and the app locks at once)")
        check(LimitMath.usedAtLeast(level: 9, limit: 30) == 27, "level 9 of 30 proves 27 min")
        check(LimitMath.level(forUsed: 27, limit: 25) == 10, "27 min used on a 25-min limit = used up")
        check(LimitMath.level(forUsed: 12, limit: 30) == 4, "12 of 30 = level 4")
        // a stricter edit never grants more time than the marks' rounding (under a tenth of the old limit)
        for old in [30, 45, 60, 120] {
            for usedTrue in stride(from: 0, through: old, by: 1) {
                let level = min(9, usedTrue * 10 / old)                 // what the marks can show before the limit
                let carried = LimitMath.usedAtLeast(level: level, limit: old)
                for new in stride(from: 5, through: old, by: 5) {
                    let more = LimitMath.thresholds(limit: new, credit: carried).last!.minutes
                    let total = carried >= new ? usedTrue : usedTrue + more
                    if total > max(new, usedTrue) + old / 10 + 1 {
                        check(false, "edit \(old)→\(new) with \(usedTrue) used allows \(total) min"); break
                    }
                }
            }
        }

        // 1.0.2: time-outs
        let shorts = RulePlan(name: "Shorts", kind: .timeout, days: [2, 3, 4, 5, 6], limitMinutes: 20, breakMinutes: 10)
        check(Status.of(shorts, now: monNoon, reachedAt: nil, calendar: seoul) == .counting, "time-out counts on its days")
        let breakEnd = date("2026-10-12 12:06", seoul)
        check(Status.of(shorts, now: monNoon, reachedAt: nil, breakUntil: breakEnd, calendar: seoul) == .onBreak(until: breakEnd),
              "time-out on a break blocks until the break ends")
        check(Status.of(shorts, now: date("2026-10-12 12:07", seoul), reachedAt: nil, breakUntil: breakEnd, calendar: seoul) == .counting,
              "after the break it counts again")
        check(Status.of(shorts, now: date("2026-10-11 12:00", seoul), reachedAt: nil, calendar: seoul) == .resting, "not on Sunday")
        check(Status.of(shorts, now: monNoon, reachedAt: monNoon, calendar: seoul) == .counting, "a time-out is never 'used up'")
        check(Validate.problems(shorts, appCount: 2, hasSelection: true).isEmpty, "20 min use / 10 min break is valid")
        var noApps = shorts; noApps.name = "X"
        check(Validate.problems(noApps, appCount: 0, hasSelection: false).contains(.nothingChosen), "time-out needs apps")
        var longBreak = shorts; longBreak.breakMinutes = 121
        check(Validate.problems(longBreak, appCount: 1, hasSelection: true).contains(.limitOutOfRange), "break over 2 h is refused")
        var shortUse = shorts; shortUse.limitMinutes = 4
        check(Validate.problems(shortUse, appCount: 1, hasSelection: true).contains(.limitOutOfRange), "use under 5 min is refused")
        var moreUse = shorts; moreUse.limitMinutes = 30
        check(Change.direction(from: shorts, to: moreUse) == .looser, "more use before a break is looser")
        var shorterBreak = shorts; shorterBreak.breakMinutes = 5
        check(Change.direction(from: shorts, to: shorterBreak) == .looser, "a shorter break is looser")
        var longerBreak = shorts; longerBreak.breakMinutes = 15
        check(Change.direction(from: shorts, to: longerBreak) == .stricter, "a longer break is stricter")
        check(Policy.access(status: .onBreak(until: breakEnd), lockInUntil: nil, now: monNoon, calendar: seoul)
              == .locked(until: breakEnd, reason: .onBreak), "a strict time-out is read-only during its break")
        check(Policy.access(status: .counting, lockInUntil: nil, now: monNoon, calendar: seoul)
              == .stricterOnly(loosenFrom: date("2026-10-13 00:00", seoul)), "a counting strict time-out takes stricter changes only")

        // 1.0.2: Strict lock
        let running = RuleStatus.running(until: date("2026-10-12 17:00", seoul))
        check(Policy.access(status: running, lockInUntil: nil, strict: false, now: monNoon, calendar: seoul) == .free,
              "a running block without Strict lock can be changed")
        check(Policy.access(status: .reached(until: date("2026-10-13 00:00", seoul)), lockInUntil: nil, strict: false, now: monNoon,
                            calendar: seoul) == .free, "a used-up limit without Strict lock can be changed")
        let lockInEnd = date("2026-10-15 00:00", seoul)
        if case .locked(let until, .lockIn) = Policy.access(status: running, lockInUntil: lockInEnd, strict: false, now: monNoon, calendar: seoul) {
            check(until == lockInEnd, "lock-in holds even blocks without Strict lock")
        } else { check(false, "lock-in holds even blocks without Strict lock") }
        var relaxed = work; relaxed.strict = false
        check(Change.direction(from: work, to: relaxed) == .looser, "switching Strict lock off is looser")
        check(Change.direction(from: relaxed, to: work) == .stricter, "switching Strict lock on is stricter")

        // 1.0.2: stopping a block that isn't strict
        let five = date("2026-10-12 17:00", seoul)
        check(Status.of(work, now: monNoon, reachedAt: nil, stoppedUntil: five, calendar: seoul) == .stopped(until: five),
              "a stopped schedule stays off until its window ends")
        check(Status.of(work, now: date("2026-10-13 10:00", seoul), reachedAt: nil, stoppedUntil: five, calendar: seoul)
              == .running(until: date("2026-10-13 17:00", seoul)), "it runs again in the next window")
        check(Status.of(work, now: monNoon, reachedAt: nil, stoppedUntil: date("2026-10-12 13:00", seoul), calendar: seoul) == running,
              "a stop that ends before the block does not hide it")
        check(Status.of(shorts, now: monNoon, reachedAt: nil, breakUntil: breakEnd, stoppedUntil: breakEnd, calendar: seoul) == .stopped(until: breakEnd),
              "an ended break shows as stopped")
        check(!RuleStatus.stopped(until: five).isBlocking, "a stopped block doesn't block")

        // 1.0.2: older saved plans (no breakMinutes / strict) still load, as strict
        let old = #"{"name":"Social","kind":"limit","isOn":true,"start":{"hour":9,"minute":0},"end":{"hour":17,"minute":0},"days":[1,2,3,4,5,6,7],"limitMinutes":30}"#
        if let p = try? JSONDecoder().decode(RulePlan.self, from: Data(old.utf8)) {
            check(p.strict && p.breakMinutes == 10 && p.domains.isEmpty && p.limitMinutes == 30, "1.0.1 plan decodes as strict")
        } else { check(false, "1.0.1 plan decodes") }
        if let back = try? JSONDecoder().decode(RulePlan.self, from: JSONEncoder().encode(shorts)) {
            check(back == shorts, "time-out round-trips")
        } else { check(false, "time-out round-trips") }

        // 1.0.2: capacity — a time-out needs two monitors
        let limitPlan = RulePlan(name: "L", kind: .limit, limitMinutes: 30)
        check(Capacity.fits(Array(repeating: limitPlan, count: 18)), "18 limits fit")
        check(!Capacity.fits(Array(repeating: limitPlan, count: 19)), "19 don't")
        check(Capacity.fits(Array(repeating: shorts, count: 9)), "9 time-outs fit")
        check(!Capacity.fits(Array(repeating: shorts, count: 10)), "10 time-outs don't")
        var offShorts = shorts; offShorts.isOn = false
        check(Capacity.fits(Array(repeating: shorts, count: 9) + [offShorts]), "a switched-off time-out needs no monitor")
        check(!Capacity.fits(Array(repeating: limitPlan, count: 18) + [offShorts]), "but every block keeps a slot (18 max)")

        // 1.1: a block's own reset time
        let four = TimeOfDay(4, 0)
        check(TimeOfDay.midnight.minuteBefore == TimeOfDay(23, 59) && four.minuteBefore == TimeOfDay(3, 59), "minute before wraps")
        let tue2 = date("2026-10-13 02:00", seoul), tue5 = date("2026-10-13 05:00", seoul)
        check(Period.start(containing: tue2, resetAt: four, calendar: seoul) == date("2026-10-12 04:00", seoul), "2 AM belongs to the period that began at 4 AM yesterday")
        check(Period.end(after: tue2, resetAt: four, calendar: seoul) == date("2026-10-13 04:00", seoul), "…and ends at 4 AM today")
        check(Period.start(containing: tue5, resetAt: four, calendar: seoul) == date("2026-10-13 04:00", seoul), "5 AM is in today's period")
        check(Period.end(after: tue5, resetAt: four, calendar: seoul) == date("2026-10-14 04:00", seoul), "…which ends at 4 AM tomorrow")
        check(Period.start(containing: date("2026-10-13 04:00", seoul), resetAt: four, calendar: seoul) == date("2026-10-13 04:00", seoul), "the reset minute starts the new period")
        check(Period.weekday(containing: tue2, resetAt: four, calendar: seoul) == 2, "2 AM Tuesday counts as Monday")
        check(Period.start(containing: tue2, resetAt: .midnight, calendar: seoul) == date("2026-10-13 00:00", seoul)
              && Period.end(after: tue2, resetAt: .midnight, calendar: seoul) == date("2026-10-14 00:00", seoul), "midnight reset = the calendar day")
        let late = RulePlan(name: "Social", kind: .limit, days: [2], limitMinutes: 60, resetAt: four)   // Mondays only
        check(Status.of(late, now: tue2, reachedAt: nil, calendar: seoul) == .counting, "Monday's limit still counts at 2 AM Tuesday")
        check(Status.of(late, now: tue5, reachedAt: nil, calendar: seoul) == .resting, "…and rests after the 4 AM reset")
        let usedUpAt1 = date("2026-10-13 01:00", seoul)
        check(Status.of(late, now: tue2, reachedAt: usedUpAt1, calendar: seoul) == .reached(until: date("2026-10-13 04:00", seoul)),
              "used up at 1 AM locks until the 4 AM reset")
        var everyDay = late; everyDay.days = Set(1...7)
        check(Status.of(everyDay, now: tue5, reachedAt: usedUpAt1, calendar: seoul) == .counting, "after the reset it counts again")
        check(Status.of(everyDay, now: date("2026-10-12 23:00", seoul), reachedAt: date("2026-10-12 22:00", seoul), calendar: seoul)
              == .reached(until: date("2026-10-13 04:00", seoul)), "used up at 10 PM stays locked past midnight, until 4 AM")
        let lateTimeout = RulePlan(name: "Shorts", kind: .timeout, days: [2], limitMinutes: 20, breakMinutes: 10, resetAt: four)
        check(Status.of(lateTimeout, now: tue2, reachedAt: nil, calendar: seoul) == .counting, "a Monday time-out still counts at 2 AM Tuesday")
        check(Policy.access(status: .counting, lockInUntil: nil, now: tue2, calendar: seoul, nextReset: date("2026-10-13 04:00", seoul))
              == .stricterOnly(loosenFrom: date("2026-10-13 04:00", seoul)), "looser changes wait for the block's own reset")
        var resetLater = everyDay; resetLater.resetAt = TimeOfDay(6, 0)
        check(Change.direction(from: everyDay, to: resetLater) == .looser, "a new reset time waits for the next reset")
        if let p = try? JSONDecoder().decode(RulePlan.self, from: Data(old.utf8)) {
            check(p.resetAt == .midnight, "older saved plans reset at midnight")
        } else { check(false, "older plans decode") }
        if let back = try? JSONDecoder().decode(RulePlan.self, from: JSONEncoder().encode(late)) {
            check(back.resetAt == four, "reset time round-trips")
        } else { check(false, "reset time round-trips") }
        // daylight saving: a 2:30 AM reset on the night the clocks skip 2–3 AM still gives sane, increasing periods
        let nyc = calendar("America/New_York")
        let springNight = date("2026-03-08 01:30", nyc)
        let half2 = TimeOfDay(2, 30)
        let s0 = Period.start(containing: springNight, resetAt: half2, calendar: nyc)
        let e0 = Period.end(after: springNight, resetAt: half2, calendar: nyc)
        check(s0 <= springNight && e0 > springNight && e0.timeIntervalSince(s0) > 20 * 3600 && e0.timeIntervalSince(s0) < 26 * 3600,
              "spring-forward night: the period still contains now and lasts about a day")
        let after = Period.end(after: e0, resetAt: half2, calendar: nyc)
        check(after > e0, "the next reset after the skipped hour comes later")

        // 1.1 review fixes
        let ten = TimeOfDay(22, 0)
        let weekdaysLate = RulePlan(name: "Work apps", kind: .limit, days: [2, 3, 4, 5, 6], limitMinutes: 60, resetAt: ten)
        check(Status.of(weekdaysLate, now: date("2026-10-17 12:00", seoul), reachedAt: nil, calendar: seoul) == .resting,
              "a 10 PM reset: Saturday noon belongs to Saturday (not Friday)")
        check(Status.of(weekdaysLate, now: date("2026-10-12 12:00", seoul), reachedAt: nil, calendar: seoul) == .counting,
              "…and Monday noon to Monday")
        check(Period.weekday(containing: date("2026-10-16 23:00", seoul), resetAt: ten, calendar: seoul) == 7,
              "Friday 11 PM with a 10 PM reset counts as Saturday")
        // a lock-in holds a queued change: it must land on the block's own reset, not on the lock-in's midnight
        var heldLimit: [RuleRecord<[String]>] = [RuleRecord(plan: late, selection: [], pending: PendingChange(
            plan: everyDay, selection: nil, effectiveAt: date("2026-10-13 04:00", seoul)))]
        let lockEnd = date("2026-10-14 00:00", seoul)
        check(Pending.holdForLockIn(&heldLimit, lockInUntil: lockEnd, calendar: seoul), "a held change moves")
        check(heldLimit[0].pending?.effectiveAt == date("2026-10-14 04:00", seoul), "…to the first 4 AM reset after the lock-in")
        check(Pending.applyDue(&heldLimit, now: lockEnd, frozenUntil: nil).isEmpty, "nothing applies at the lock-in's midnight")
        check(Pending.applyDue(&heldLimit, now: date("2026-10-14 04:00", seoul), frozenUntil: nil).count == 1, "it applies at 4 AM")
        var heldMidnight: [RuleRecord<[String]>] = [RuleRecord(plan: RulePlan(name: "M", kind: .limit, limitMinutes: 30), selection: [],
            pending: PendingChange(plan: RulePlan(name: "M", kind: .limit, limitMinutes: 60), selection: nil, effectiveAt: date("2026-10-13 00:00", seoul)))]
        Pending.holdForLockIn(&heldMidnight, lockInUntil: lockEnd, calendar: seoul)
        check(heldMidnight[0].pending?.effectiveAt == lockEnd, "a midnight block's change still lands when the lock-in ends")
        check(Pending.effectiveDate(date("2026-10-13 04:00", seoul), plan: late, lockInUntil: lockEnd, now: date("2026-10-12 12:00", seoul), calendar: seoul)
              == date("2026-10-14 04:00", seoul), "the app shows the real date")

        print(failures == 0 ? "OK — \(checks) checks passed" : "\(failures) of \(checks) checks FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
