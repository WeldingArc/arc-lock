import DeviceActivity
import FamilyControls
import SwiftUI

enum EditorTarget: Identifiable, Hashable {
    case new(RuleKind)
    case edit(UUID)
    var id: String {
        switch self { case .new(let k): return "new-\(k.rawValue)"; case .edit(let id): return id.uuidString }
    }
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @State private var editing: EditorTarget?
    @State private var showBlockNow = false
    @State private var showLockIn = false
    @State private var stopping: StopTarget?

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 18) {
                header
                StatusHero()
                sessionArea
                lockInArea
                section(title: "Schedules", kind: .schedule, rules: model.schedules,
                        empty: "Pick apps and websites and the hours they stay locked.")
                section(title: "Daily limits", kind: .limit, rules: model.limits,
                        empty: "After the time you allow each day, apps lock until midnight.")
                    .id("limits")
                section(title: "Time-outs", kind: .timeout, rules: model.timeouts,
                        empty: "After a stretch of use, apps take a short break, then open again.")
                    .id("timeouts")
                Text(model.strictLockActive
                     ? "Blocks with Strict lock can't be changed or stopped while they run. With deletion protection on, no app can be deleted."
                     : "Strict lock is off, so any block can be stopped.")
                    .font(.p(13, .regular, .footnote))
                    .foregroundStyle(Palette.faint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .scrollIndicators(.hidden)
        #if DEBUG
        .task {
            if Demo.shot == "limits" || Demo.shot == "timeouts" {
                try? await Task.sleep(for: .milliseconds(300))
                proxy.scrollTo(Demo.shot, anchor: .top)
            }
        }
        #endif
        }
        .sheet(item: $editing) { target in RuleEditor(target: target).environmentObject(model) }
        .sheet(isPresented: $showBlockNow) { BlockNowSheet().environmentObject(model) }
        .sheet(isPresented: $showLockIn) { LockInSheet().environmentObject(model) }
        .confirmationDialog(Text(stopping?.title ?? ""), isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }),
                            titleVisibility: .visible, presenting: stopping) { target in
            Button(target.action) { stop(target) }
        } message: { target in
            Text(target.message)
        }
        #if DEBUG
        .onAppear {
            switch Demo.shot {
            case "editor": editing = .edit(Demo.study)
            case "limit": editing = .edit(Demo.social)
            case "timeout": editing = .edit(Demo.shorts)
            case "blocknow": showBlockNow = true
            case "settings", "guide", "appearance": model.showSettings = true
            case "lockin": showLockIn = true
            default: break
            }
        }
        #endif
    }

    private var header: some View {
        ZStack {
            Eyebrow("Arc Lock")
            HStack {
                Spacer()
                Button { model.showSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 19, weight: .light)).foregroundStyle(Palette.muted)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(Text("Settings"))
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var sessionArea: some View {
        if let s = model.activeSession {
            Card(glow: true) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Block now").font(.p(19, .regular, .title3)).foregroundStyle(Palette.ink)
                        Spacer()
                        Pill(text: String(localized: "Until \(Fmt.moment(s.endsAt, now: model.now))"), tint: Palette.brass, icon: "lock.fill")
                    }
                    Text(model.canStopSession ? "\(durationText(s.endsAt.timeIntervalSince(model.now))) left"
                                              : "\(durationText(s.endsAt.timeIntervalSince(model.now))) left · can't be stopped")
                        .font(.p(14, .regular, .subheadline)).foregroundStyle(Palette.muted)
                    if !s.selection.isEmpty { TokenIcons(selection: s.selection) }
                    if model.canStopSession {
                        HStack {
                            Spacer()
                            StopButton { stopping = .session(until: s.endsAt) }
                        }
                    }
                }
            }
        } else {
            Button { showBlockNow = true } label: {
                Label("Block now", systemImage: "lock")
            }
            .buttonStyle(BrassButton())
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder private var lockInArea: some View {
        if model.lockInActive, let until = model.state.lockInUntil {
            Button { showLockIn = true } label: { LockInBanner(until: until) }.buttonStyle(.plain)
        } else {
            Button { showLockIn = true } label: {
                Card {
                    HStack(spacing: 14) {
                        Image(systemName: "lock.shield").font(.system(size: 22, weight: .light)).foregroundStyle(Palette.brass)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Lock in").font(.p(17, .regular)).foregroundStyle(Palette.ink)
                            Text("Freeze every rule for days. No early exit.").font(.p(14, .regular)).foregroundStyle(Palette.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Palette.faint)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func section(title: LocalizedStringKey, kind: RuleKind, rules: [Rule], empty: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Eyebrow(title, color: Palette.muted)
                Spacer()
                if !rules.isEmpty {
                    Button { editing = .new(kind) } label: {
                        Image(systemName: "plus").font(.system(size: 16, weight: .regular)).foregroundStyle(Palette.brass)
                            .frame(width: 44, height: 32)
                    }
                    .accessibilityLabel(Text(addTitle(kind)))
                    .disabled(!model.canAdd(kind))
                }
            }
            .padding(.horizontal, 4)
            if rules.isEmpty {
                Card {
                    VStack(spacing: 14) {
                        Text(empty).font(.p(15, .regular)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                        Button(addTitle(kind)) { editing = .new(kind) }
                            .buttonStyle(GhostButton(tint: Palette.brass))
                            .disabled(!model.canAdd(kind))
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                ForEach(rules) { rule in
                    let stoppable = model.canStop(rule)
                    Button { editing = .edit(rule.id) } label: { RuleRow(rule: rule, stoppable: stoppable) }
                        .buttonStyle(.plain)
                        // on top of the card, not inside its button, so a tap on Stop never opens the editor
                        .overlay(alignment: .bottomTrailing) {
                            if stoppable {
                                StopButton { stopping = StopTarget(rule, model.status(rule)) }.padding(20)
                            }
                        }
                }
            }
        }
        .padding(.top, 10)
    }

    private func addTitle(_ kind: RuleKind) -> LocalizedStringKey {
        switch kind {
        case .schedule: "Add a schedule"
        case .limit: "Add a daily limit"
        case .timeout: "Add a time-out"
        }
    }

    private func stop(_ target: StopTarget) {
        let outcome: AppModel.Outcome
        switch target {
        case .rule(let id, _, _): outcome = model.stop(id)
        case .session: outcome = model.stopSession()
        }
        switch outcome {
        case .refused(let why): model.problem = why
        default: model.toast = target.done
        }
    }
}

/// A block without Strict lock that the user asked to stop, and what to say about it.
enum StopTarget: Identifiable {
    case rule(UUID, name: String, status: RuleStatus)
    case session(until: Date)

    init(_ rule: Rule, _ status: RuleStatus) { self = .rule(rule.id, name: rule.plan.name, status: status) }

    var id: String {
        switch self { case .rule(let id, _, _): id.uuidString; case .session: "session" }
    }
    var title: String {
        switch self {
        case .rule(_, let name, .onBreak): String(localized: "End the break for \(name)?")
        case .rule(_, let name, _): String(localized: "Stop \(name)?")
        case .session: String(localized: "Stop Block now?")
        }
    }
    var message: String {
        switch self {
        case .rule(_, _, .running(let until)):
            String(localized: "It stays off until \(Fmt.time(until)) and starts again on its own next time.")
        case .rule(_, _, .reached): String(localized: "The apps open until midnight. The limit starts again tomorrow.")
        case .rule(_, _, .onBreak): String(localized: "The apps open now and the count starts over.")
        case .rule: String(localized: "It starts again on its own next time.")
        case .session: String(localized: "The apps open now.")
        }
    }
    var action: String {
        switch self {
        case .rule(_, _, .running(let until)): String(localized: "Stop until \(Fmt.time(until))")
        case .rule(_, _, .reached): String(localized: "Stop for today")
        case .rule(_, _, .onBreak): String(localized: "End break")
        case .rule: String(localized: "Stop")
        case .session: String(localized: "Stop Block now")
        }
    }
    var done: String {
        switch self {
        case .rule(_, let name, .onBreak): String(localized: "The break for \(name) is over.")
        case .rule(_, let name, _): String(localized: "\(name) is stopped.")
        case .session: String(localized: "Block now is stopped.")
        }
    }
}

/// Small "Stop" control on a block without Strict lock.
struct StopButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "stop.circle").font(.system(size: 13, weight: .regular))
                Text("Stop").font(.p(13, .medium, .footnote))
            }
            .foregroundStyle(Palette.brass)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Palette.brass.opacity(0.12)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct StatusHero: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        let blocks = model.blockingNow
        VStack(spacing: 12) {
            ArcMark(size: 76, locked: !blocks.isEmpty)
                .padding(.top, 8)
            Text(blocks.isEmpty ? "Unlocked" : "Locked")
                .font(.p(44, .extraLight, .largeTitle))
                .foregroundStyle(Palette.ink)
            if let first = blocks.first {
                VStack(spacing: 4) {
                    ForEach(Array(blocks.prefix(3).enumerated()), id: \.offset) { _, b in
                        Text("\(b.name) · until \(Fmt.moment(b.until, now: model.now))")
                            .font(.p(16, .regular, .body)).foregroundStyle(Palette.muted)
                    }
                    if blocks.count > 3 {
                        Text("and \(blocks.count - 3) more").font(.p(14, .regular)).foregroundStyle(Palette.faint)
                    }
                }
                Text("Next unlock in \(durationText(first.until.timeIntervalSince(model.now)))")
                    .font(.p(13, .medium, .caption)).foregroundStyle(Palette.brass)
                    .padding(.top, 2)
            } else if let next = model.nextStart {
                Text("Next: \(next.name) at \(Fmt.moment(next.at, now: model.now))")
                    .font(.p(16, .regular)).foregroundStyle(Palette.muted)
            } else if model.state.rules.isEmpty {
                Text("Nothing is blocked yet.")
                    .font(.p(16, .regular)).foregroundStyle(Palette.muted)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

struct RuleRow: View {
    @EnvironmentObject private var model: AppModel
    let rule: Rule
    /// The block isn't strict and is blocking right now: leave room for the Stop button laid over the card.
    var stoppable = false

    var body: some View {
        let status = model.status(rule)
        Card(glow: status.isBlocking) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(rule.plan.name).font(.p(19, .regular, .title3)).foregroundStyle(rule.plan.isOn ? Palette.ink : Palette.faint)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    statusPill(status)
                }
                Text(summary).font(.p(14, .regular, .subheadline)).foregroundStyle(Palette.muted)
                if !rule.selection.isEmpty || !rule.plan.domains.isEmpty || isDemo {
                    HStack(spacing: 8) {
                        TokenIcons(selection: rule.selection, demoName: rule.plan.name)
                        if !rule.plan.domains.isEmpty {
                            Pill(text: rule.plan.domains.count == 1 ? rule.plan.domains[0] : String(localized: "\(rule.plan.domains.count) websites"), icon: "globe")
                        }
                    }
                }
                if rule.plan.kind.countsUse, rule.plan.isOn {
                    switch status {
                    case .reached:
                        Text("All used. Locked until midnight.").font(.p(12, .regular, .caption)).foregroundStyle(Palette.rose)
                    case .counting, .onBreak:
                        UsageLine(rule: rule)
                    default:
                        EmptyView()
                    }
                }
                if let p = rule.pending {
                    HStack(spacing: 6) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 12))
                        Text(p.plan == nil ? "Will be deleted at \(Fmt.moment(model.effectiveDate(p), now: model.now))"
                                           : "Your changes start at \(Fmt.moment(model.effectiveDate(p), now: model.now))")
                            .font(.p(13, .regular, .footnote))
                    }
                    .foregroundStyle(Palette.brass)
                }
                if stoppable {
                    HStack {
                        Spacer()
                        StopButton {}.hidden().accessibilityHidden(true)
                    }
                }
            }
        }
        .opacity(rule.plan.isOn ? 1 : 0.7)
        .accessibilityElement(children: .combine)
    }

    private var isDemo: Bool {
        #if DEBUG
        return Demo.isOn
        #else
        return false
        #endif
    }

    private var summary: String {
        let p = rule.plan
        switch p.kind {
        case .schedule: return "\(p.start.text) – \(p.end.text) · \(p.days.dayText)"
        case .limit: return String(localized: "\(minutesText(p.limitMinutes)) a day · \(p.days.dayText)")
        case .timeout: return String(localized: "\(minutesText(p.breakMinutes)) break after \(minutesText(p.limitMinutes)) · \(p.days.dayText)")
        }
    }

    @ViewBuilder private func statusPill(_ s: RuleStatus) -> some View {
        switch s {
        case .off: Pill(text: String(localized: "Off"), tint: Palette.faint)
        case .waiting(let next):
            if let next { Pill(text: String(localized: "Starts \(Fmt.moment(next, now: model.now))")) } else { Pill(text: String(localized: "No days")) }
        case .running(let until): Pill(text: String(localized: "Until \(Fmt.moment(until, now: model.now))"), tint: Palette.brass, icon: "lock.fill")
        case .counting: Pill(text: String(localized: "Counting"), tint: Palette.sage)
        case .resting: Pill(text: String(localized: "Not today"), tint: Palette.faint)
        case .reached: Pill(text: String(localized: "Used up"), tint: Palette.rose, icon: "lock.fill")
        case .onBreak(let until): Pill(text: String(localized: "Break until \(Fmt.time(until))"), tint: Palette.brass, icon: "cup.and.saucer.fill")
        case .stopped(let until): Pill(text: String(localized: "Stopped until \(Fmt.moment(until, now: model.now))"), tint: Palette.faint, icon: "pause.fill")
        }
    }
}

/// Today's exact use, drawn by the usage report extension (iOS hands the minutes only to it).
struct UsageLine: View {
    @EnvironmentObject private var model: AppModel
    let rule: Rule
    @ScaledMetric(relativeTo: .caption) private var line: CGFloat = 17

    var body: some View {
        content.frame(height: rule.plan.kind == .limit ? line + 12 : line)
    }

    @ViewBuilder private var content: some View {
        #if DEBUG
        if Demo.isOn { UsageView(usage: Demo.usage(rule.id)) } else { report }
        #else
        report
        #endif
    }

    @ViewBuilder private var report: some View {
        if let slot = model.state.slot(of: rule.id) {
            DeviceActivityReport(.init(UsageSummary.context(slot: slot)), filter: filter)
                .id(model.reportEpoch)
        }
    }

    private var filter: DeviceActivityFilter {
        let s = rule.selection
        let today = Calendar.current.dateInterval(of: .day, for: model.now) ?? DateInterval(start: model.now, duration: 1)
        return DeviceActivityFilter(segment: .hourly(during: today), devices: .init([.iPhone]),
                                    applications: s.applicationTokens, categories: s.categoryTokens, webDomains: s.webDomainTokens)
    }
}

struct LockInBanner: View {
    let until: Date
    var body: some View {
        Card(glow: true) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.shield").font(.system(size: 22, weight: .light)).foregroundStyle(Palette.brass)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Locked in through \(Fmt.lastDay(endingAt: until))").font(.p(16, .medium)).foregroundStyle(Palette.ink)
                    Text("No rule can be loosened or deleted, and no app can be deleted. You can still add blocks.")
                        .font(.p(14, .regular, .subheadline)).foregroundStyle(Palette.muted)
                }
            }
        }
    }
}
