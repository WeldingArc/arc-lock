import FamilyControls
import SwiftUI

/// Every schedule, daily limit and time-out. Tap one to change it; + adds a new one. A running block without
/// Strict lock shows Stop (and can be swiped to stop).
struct BlocksTab: View {
    @EnvironmentObject private var model: AppModel
    let openBlockNow: () -> Void
    @State private var editing: EditorTarget?
    @State private var stopping: StopTarget?

    var body: some View {
        NavigationStack {
            List {
                section("Schedules", kind: .schedule, rules: model.schedules,
                        empty: "Pick apps and websites and the hours they stay locked.")
                section("Daily limits", kind: .limit, rules: model.limits,
                        empty: "After the time you allow each day, apps lock until the limit resets.")
                section("Time-outs", kind: .timeout, rules: model.timeouts,
                        empty: "After a stretch of use, apps take a short break, then open again.")
                Section {} footer: {
                    Text(model.strictLockActive
                         ? "Blocks with Strict lock can't be changed or stopped while they run. With deletion protection on, no app can be deleted."
                         : "Strict lock is off: blocks can be stopped (a strict daily limit or time-out stays strict until its next reset).")
                }
            }
            .themedList()
            .blockNowButton(openBlockNow)
            .navigationTitle("Blocks")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(RuleKind.allCases, id: \.self) { kind in
                            Button { editing = .new(kind) } label: { Label(addTitle(kind), systemImage: icon(kind)) }
                                .disabled(!model.canAdd(kind))
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text("Add a block"))
                }
            }
            .sheet(item: $editing) { target in RuleEditor(target: target).environmentObject(model) }
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
                default: break
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, kind: RuleKind, rules: [Rule], empty: LocalizedStringKey) -> some View {
        Section {
            if rules.isEmpty {
                Button { editing = .new(kind) } label: { Label(addTitle(kind), systemImage: "plus.circle") }
                    .disabled(!model.canAdd(kind))
            }
            ForEach(rules) { rule in
                let stoppable = model.canStop(rule)
                BlockRow(rule: rule, onEdit: { editing = .edit(rule.id) },
                         onStop: stoppable ? { stopping = StopTarget(rule, model.status(rule)) } : nil)
                    .swipeActions(edge: .trailing) {
                        if stoppable {
                            Button { stopping = StopTarget(rule, model.status(rule)) } label: { Label("Stop", systemImage: "stop.circle") }
                                .tint(Palette.brass)
                        }
                    }
            }
        } header: {
            Text(title)
        } footer: {
            if rules.isEmpty { Text(empty) }
        }
        .listRowBackground(Palette.card)
    }

    private func addTitle(_ kind: RuleKind) -> LocalizedStringKey {
        switch kind {
        case .schedule: "New schedule"
        case .limit: "New daily limit"
        case .timeout: "New time-out"
        }
    }

    private func icon(_ kind: RuleKind) -> String {
        switch kind {
        case .schedule: "calendar.badge.clock"
        case .limit: "hourglass"
        case .timeout: "cup.and.saucer"
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

/// One block in the list: name and state, its hours or limits, what it blocks, and today's use.
struct BlockRow: View {
    @EnvironmentObject private var model: AppModel
    let rule: Rule
    let onEdit: () -> Void
    /// Set when the block isn't strict and is blocking right now.
    var onStop: (() -> Void)?

    var body: some View {
        // two separate buttons (plain/borderless), so a tap on Stop never opens the editor
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onEdit) { details.contentShape(Rectangle()) }
                .buttonStyle(.borderless)
                .tint(Palette.ink)
            if let onStop {
                Button(action: onStop) { Label("Stop", systemImage: "stop.circle") }
                    .buttonStyle(.borderless)
                    .font(.p(14, .medium, .subheadline))
                    .tint(Palette.brass)
            }
        }
        .padding(.vertical, 6)
        .opacity(rule.plan.isOn ? 1 : 0.7)
    }

    private var details: some View {
        let status = model.status(rule)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(rule.plan.name).font(.p(17, .semibold, .headline))
                    .foregroundStyle(rule.plan.isOn ? Palette.ink : Palette.faint)
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
                case .reached(let until):
                    Text("All used. Locked until \(Fmt.moment(until, now: model.now)).")
                        .font(.p(13, .regular, .footnote)).foregroundStyle(Palette.rose)
                case .counting, .onBreak:
                    UsageLine(rule: rule)
                default:
                    EmptyView()
                }
            }
            if let p = rule.pending {
                Label(p.plan == nil ? "Will be deleted at \(Fmt.moment(model.effectiveDate(p, plan: rule.plan), now: model.now))"
                                    : "Your changes start at \(Fmt.moment(model.effectiveDate(p, plan: rule.plan), now: model.now))",
                      systemImage: "clock.arrow.circlepath")
                    .font(.p(13, .regular, .footnote)).foregroundStyle(Palette.brass)
            }
        }
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
        let reset = p.resetAt == .midnight ? "" : " · " + String(localized: "resets \(p.resetAt.text)")
        switch p.kind {
        case .schedule: return "\(p.start.text) – \(p.end.text) · \(p.days.dayText)"
        case .limit: return String(localized: "\(minutesText(p.limitMinutes)) a day · \(p.days.dayText)") + reset
        case .timeout: return String(localized: "\(minutesText(p.breakMinutes)) break after \(minutesText(p.limitMinutes)) · \(p.days.dayText)") + reset
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
