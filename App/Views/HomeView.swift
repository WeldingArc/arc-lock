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

/// Home: are things locked right now, what's blocking, Lock in, and what starts next.
struct HomeTab: View {
    @EnvironmentObject private var model: AppModel
    let openBlockNow: () -> Void
    @State private var showLockIn = false

    var body: some View {
        NavigationStack {
            List {
                Section { StatusHero() }
                    .listRowBackground(Color.clear)
                let blocks = model.blockingNow
                if !blocks.isEmpty {
                    Section("Blocking now") {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                            HStack(spacing: 12) {
                                Image(systemName: b.kind == .timeout ? "cup.and.saucer.fill" : (b.kind == .place ? "mappin.circle.fill" : "lock.fill"))
                                    .foregroundStyle(Palette.brass).frame(width: 22)
                                if let r = b.rule { BlockName(rule: r).foregroundStyle(Palette.ink).lineLimit(1) }
                                else { Text(b.name).foregroundStyle(Palette.ink) }
                                Spacer()
                                Text(b.until == .distantFuture ? String(localized: "until you leave")
                                                               : String(localized: "until \(Fmt.moment(b.until, now: model.now))"))
                                    .foregroundStyle(Palette.muted)
                            }
                            .font(.p(16, .regular))
                        }
                    }
                    .listRowBackground(Palette.card)
                }
                Section {
                    Button { showLockIn = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "lock.shield").foregroundStyle(Palette.brass).frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                if model.lockInActive, let until = model.state.lockInUntil {
                                    Text("Locked in through \(Fmt.lastDay(endingAt: until))").foregroundStyle(Palette.ink)
                                } else {
                                    Text("Lock in").foregroundStyle(Palette.ink)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
                        }
                        .font(.p(16, .regular))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text(model.lockInActive ? "No rule can be loosened or deleted, and no app can be deleted. You can still add blocks."
                                            : "Freeze every rule for days. No early exit.")
                }
                .listRowBackground(Palette.card)
                if let next = model.nextStart {
                    Section("Up next") {
                        HStack {
                            BlockName(rule: next.rule).foregroundStyle(Palette.ink).lineLimit(1)
                            Spacer()
                            Text(Fmt.moment(next.at, now: model.now)).foregroundStyle(Palette.muted)
                        }
                        .font(.p(16, .regular))
                    }
                    .listRowBackground(Palette.card)
                }
            }
            .themedList()
            .blockNowButton(openBlockNow)
            .navigationTitle("Arc Lock")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showLockIn) { LockInSheet().environmentObject(model) }
            #if DEBUG
            .onAppear { if Demo.shot == "lockin" { showLockIn = true } }
            #endif
        }
    }
}

/// The phone-and-lock mark, closed while anything is blocked, with how long until the next unlock.
struct StatusHero: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        let blocks = model.blockingNow
        VStack(spacing: 10) {
            ArcMark(size: 84, locked: !blocks.isEmpty)
            Text(blocks.isEmpty ? "Unlocked" : "Locked")
                .font(.p(40, .light, .largeTitle))
                .foregroundStyle(Palette.ink)
            if let first = blocks.first {
                Text(first.until == .distantFuture ? String(localized: "Unlocks when you leave")
                                                   : String(localized: "Next unlock in \(durationText(first.until.timeIntervalSince(model.now)))"))
                    .font(.p(15, .medium, .subheadline)).foregroundStyle(Palette.brass)
            } else if model.state.rules.isEmpty && model.activeSession == nil {
                Text("Nothing is blocked yet.").font(.p(15, .regular, .subheadline)).foregroundStyle(Palette.muted)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

/// A block without Strict lock that the user asked to stop, and what to say about it.
enum StopTarget: Identifiable {
    /// `name` is empty when none was typed (the dialogs then say "this block").
    case rule(UUID, name: String, status: RuleStatus)
    case session(until: Date)

    init(_ rule: Rule, _ status: RuleStatus) {
        self = .rule(rule.id, name: rule.plan.hasName ? rule.plan.displayName : "", status: status)
    }

    var id: String {
        switch self { case .rule(let id, _, _): id.uuidString; case .session: "session" }
    }
    var title: String {
        switch self {
        case .rule(_, let name, .onBreak) where !name.isEmpty: String(localized: "End the break for \(name)?")
        case .rule(_, _, .onBreak): String(localized: "End this break?")
        case .rule(_, let name, _) where !name.isEmpty: String(localized: "Stop \(name)?")
        case .rule: String(localized: "Stop this block?")
        case .session: String(localized: "Stop Block now?")
        }
    }
    var message: String {
        switch self {
        case .rule(_, _, .running(let until)):
            String(localized: "It stays off until \(Fmt.time(until)) and starts again on its own next time.")
        case .rule(_, _, .reached(let until)): String(localized: "The apps open until \(Fmt.moment(until)). Then the limit starts again.")
        case .rule(_, _, .onBreak): String(localized: "The apps open now and the count starts over.")
        case .rule(_, _, .atPlace): String(localized: "The apps open now. It starts again the next time you arrive.")
        case .rule: String(localized: "It starts again on its own next time.")
        case .session: String(localized: "The apps open now.")
        }
    }
    var action: String {
        switch self {
        case .rule(_, _, .running(let until)): String(localized: "Stop until \(Fmt.time(until))")
        case .rule(_, _, .reached): String(localized: "Stop until it resets")
        case .rule(_, _, .onBreak): String(localized: "End break")
        case .rule: String(localized: "Stop")
        case .session: String(localized: "Stop Block now")
        }
    }
    var done: String {
        switch self {
        case .rule(_, let name, .onBreak) where !name.isEmpty: String(localized: "The break for \(name) is over.")
        case .rule(_, _, .onBreak): String(localized: "The break is over.")
        case .rule(_, let name, _) where !name.isEmpty: String(localized: "\(name) is stopped.")
        case .rule: String(localized: "The block is stopped.")
        case .session: String(localized: "Block now is stopped.")
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
        // the block's own day: from its last reset to the next (midnight to midnight by default)
        let period = DateInterval(start: model.periodStart(rule.plan), end: model.nextReset(rule.plan))
        return DeviceActivityFilter(segment: .hourly(during: period), devices: .init([.iPhone]),
                                    applications: s.applicationTokens, categories: s.categoryTokens, webDomains: s.webDomainTokens)
    }
}
