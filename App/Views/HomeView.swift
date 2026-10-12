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
    @State private var showSettings = false

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 18) {
                header
                StatusHero()
                sessionArea
                if model.lockInActive, let until = model.state.lockInUntil { LockInBanner(until: until) }
                section(title: "Schedules", kind: .schedule, rules: model.schedules,
                        empty: "Pick apps and websites and the hours they stay locked.")
                section(title: "Daily limits", kind: .limit, rules: model.limits,
                        empty: "After the time you allow each day, apps lock until midnight.")
                    .id("limits")
                Text("While a block runs it can't be changed or stopped, and no app can be deleted. While any block is switched on, the clock stays automatic.")
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
        .task { if Demo.shot == "limits" { try? await Task.sleep(for: .milliseconds(300)); proxy.scrollTo("limits", anchor: .top) } }
        #endif
        }
        .sheet(item: $editing) { target in RuleEditor(target: target).environmentObject(model) }
        .sheet(isPresented: $showBlockNow) { BlockNowSheet().environmentObject(model) }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
        #if DEBUG
        .onAppear {
            switch Demo.shot {
            case "editor": editing = .edit(Demo.study)
            case "limit": editing = .edit(Demo.social)
            case "blocknow": showBlockNow = true
            case "settings", "lockin", "guide": showSettings = true
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
                Button { showSettings = true } label: {
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
                    Text("\(durationText(s.endsAt.timeIntervalSince(model.now))) left · can't be stopped")
                        .font(.p(14, .regular, .subheadline)).foregroundStyle(Palette.muted)
                    if !s.selection.isEmpty { TokenIcons(selection: s.selection) }
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
                    .accessibilityLabel(Text(kind == .schedule ? "Add a schedule" : "Add a daily limit"))
                    .disabled(!model.canAddRule)
                }
            }
            .padding(.horizontal, 4)
            if rules.isEmpty {
                Card {
                    VStack(spacing: 14) {
                        Text(empty).font(.p(15, .regular)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                        Button(kind == .schedule ? "Add a schedule" : "Add a daily limit") { editing = .new(kind) }
                            .buttonStyle(GhostButton(tint: Palette.brass))
                            .disabled(!model.canAddRule)
                    }
                    .frame(maxWidth: .infinity)
                }
            } else {
                ForEach(rules) { rule in
                    Button { editing = .edit(rule.id) } label: { RuleRow(rule: rule) }
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 10)
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
                if rule.plan.kind == .limit, rule.plan.isOn, status != .resting {
                    UsageBar(level: model.usageLevel(rule))
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
        }
    }
}

/// Today's use of a daily limit in tenths (Screen Time reports thresholds, not exact minutes).
struct UsageBar: View {
    let level: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                ForEach(1...10, id: \.self) { k in
                    Capsule().fill(k <= level ? (level >= 10 ? Palette.rose : Palette.sage) : Color.white.opacity(0.07))
                        .frame(height: 5)
                }
            }
            Text(caption).font(.p(12, .regular, .caption)).foregroundStyle(Palette.faint)
        }
        .accessibilityElement(children: .combine)
    }
    private var caption: LocalizedStringKey {
        switch level {
        case ..<1: return "Under 10% used today"
        case 10...: return "All used — locked until midnight"
        default: return "Over \(level * 10)% used today"
        }
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
