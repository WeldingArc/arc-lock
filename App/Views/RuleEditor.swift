import FamilyControls
import SwiftUI

/// Create or change a schedule or a daily limit. What may be changed follows the lock policy:
/// read-only while it runs (or during a lock-in), looser limit changes wait until midnight.
struct RuleEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let target: EditorTarget

    @State private var plan = RulePlan()
    @State private var selection = FamilyActivitySelection()
    @State private var showPicker = false
    @State private var newDomain = ""
    @State private var domainError = false
    @State private var confirmDelete = false
    @State private var confirmStart = false
    @State private var loaded = false

    private var existing: Rule? {
        if case .edit(let id) = target { return model.state.rules.first { $0.id == id } }
        return nil
    }
    private var access: EditAccess { existing.map { model.access($0) } ?? .free }
    private var readOnly: Bool { if case .locked = access { return true }; return false }
    private var problems: [PlanProblem] {
        Validate.problems(plan, appCount: selection.applicationTokens.count, hasSelection: !selection.isEmpty,
                          webTokenCount: selection.webDomainTokens.count)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                ScrollView {
                    VStack(spacing: 18) {
                        lockNotice            // stays tappable: undoing a waiting change is always allowed
                        VStack(spacing: 18) {
                            if existing == nil { kindSwitch }
                            nameField
                            appsCard
                            if plan.kind == .schedule { websitesCard; whenCard } else { limitCard }
                            if existing != nil && !readOnly { deleteButton }
                        }
                        .disabled(readOnly)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .navigationTitle(existing == nil ? (plan.kind == .schedule ? String(localized: "New schedule") : String(localized: "New daily limit")) : plan.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(readOnly ? "Close" : "Cancel") { dismiss() }.foregroundStyle(Palette.muted)
                }
                if !readOnly {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }.font(.p(17, .semibold)).disabled(!problems.isEmpty)
                    }
                }
            }
            .familyActivityPicker(headerText: String(localized: "Choose the apps, categories and websites to block."),
                                  isPresented: $showPicker, selection: $selection)
            .confirmationDialog(Text("This block starts right away"), isPresented: $confirmStart, titleVisibility: .visible) {
                Button("Save and lock until \(Fmt.moment(startsNowUntil ?? Date(), now: model.now))") { commitSave() }
            } message: {
                Text("Its hours include the current time, so it starts now and can't be changed until \(Fmt.moment(startsNowUntil ?? Date(), now: model.now)).")
            }
            .confirmationDialog(Text("Delete this block?"), isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { delete() }
            } message: {
                if case .stricterOnly(let from) = access {
                    Text("It keeps working today and is deleted at \(Fmt.moment(from, now: model.now)).")
                }
            }
        }
        .presentationBackground(Palette.night)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let r = existing {
            // a waiting change is what the user last saved, so editing continues from it; a locked rule shows
            // the version that is running
            let locked: Bool = { if case .locked = model.access(r) { return true }; return false }()
            plan = locked ? r.plan : (r.pending?.plan ?? r.plan)
            selection = locked ? r.selection : (r.pending?.selection ?? r.selection)
        } else if case .new(let kind) = target {
            plan = RulePlan(name: "", kind: kind, start: TimeOfDay(9, 0), end: TimeOfDay(17, 0),
                            days: kind == .schedule ? [2, 3, 4, 5, 6] : Set(1...7), limitMinutes: 30)
        }
    }

    // MARK: sections

    @ViewBuilder private var lockNotice: some View {
        switch access {
        case .locked(let until, let reason):
            notice(icon: "lock.fill", text: AppModel.lockedMessage(until: until, reason: reason, now: model.now))
        case .stricterOnly(let from):
            notice(icon: "clock.arrow.circlepath",
                   text: String(localized: "Today's limit is locked in. One stricter change a day applies now; anything else — more time, fewer apps or days, deleting, or a second change — starts at \(Fmt.moment(from, now: model.now))."))
        case .free:
            EmptyView()
        }
        if let p = existing?.pending {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(p.plan == nil ? "This block will be deleted at \(Fmt.moment(model.effectiveDate(p), now: model.now))." : "Changes are waiting until \(Fmt.moment(model.effectiveDate(p), now: model.now)). Until then the current version runs.")
                        .font(.p(14, .regular)).foregroundStyle(Palette.muted)
                    Button("Keep the current version") {
                        if let id = existing?.id { model.cancelPending(id); dismiss() }
                    }
                    .font(.p(15, .medium)).foregroundStyle(Palette.brass)
                }
            }
        }
    }

    private func notice(icon: String, text: String) -> some View {
        Card(glow: true) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).foregroundStyle(Palette.brass).font(.system(size: 16))
                Text(text).font(.p(15, .regular)).foregroundStyle(Palette.ink)
            }
        }
    }

    private var kindSwitch: some View {
        HStack(spacing: 0) {
            ForEach(RuleKind.allCases, id: \.self) { k in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        plan.kind = k
                        if k == .limit && plan.days == [2, 3, 4, 5, 6] { plan.days = Set(1...7) }
                    }
                } label: {
                    Text(k == .schedule ? "Schedule" : "Daily limit")
                        .font(.p(15, plan.kind == k ? .semibold : .regular))
                        .foregroundStyle(plan.kind == k ? Palette.night : Palette.muted)
                        .frame(maxWidth: .infinity, minHeight: 42)
                        .background(Capsule().fill(plan.kind == k ? Palette.brass : .clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Palette.card))
        .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
    }

    private var nameField: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Eyebrow("Name", color: Palette.muted)
                TextField(text: $plan.name, prompt: Text(plan.kind == .schedule ? "Study, Sleep, Work…" : "Social, Games, Video…").foregroundStyle(Palette.faint)) {
                    Text("Name")
                }
                .font(.p(20, .light, .title3))
                .foregroundStyle(Palette.ink)
                .submitLabel(.done)
            }
        }
    }

    private var appsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow("Apps & websites", color: Palette.muted)
                if selection.isEmpty && !demoIcons {
                    Text("Nothing chosen yet.").font(.p(15, .regular)).foregroundStyle(Palette.faint)
                } else {
                    TokenIcons(selection: selection, max: 8, demoName: plan.name)
                    if !selection.isEmpty { Text(selectionSummary).font(.p(14, .regular)).foregroundStyle(Palette.muted) }
                }
                if !readOnly {
                    Button(selection.isEmpty ? "Choose apps & websites" : "Change") { showPicker = true }
                        .buttonStyle(GhostButton(tint: Palette.brass))
                }
                if plan.kind == .limit {
                    Text("Time in these apps and websites adds up toward one daily limit.")
                        .font(.p(13, .regular, .footnote)).foregroundStyle(Palette.faint)
                } else if !selection.webDomainTokens.isEmpty {
                    Text("Websites picked here are blocked in Safari. To block a site in every browser, also add it by address below.")
                        .font(.p(13, .regular, .footnote)).foregroundStyle(Palette.faint)
                }
                if selection.webDomainTokens.count > Limits.maxDomains {
                    Text("Choose at most \(Limits.maxDomains) websites.")
                        .font(.p(13, .regular, .footnote)).foregroundStyle(Palette.rose)
                }
                if selection.applicationTokens.count > Limits.maxApps {
                    Text("Choose at most \(Limits.maxApps) apps — or pick a whole category instead.")
                        .font(.p(13, .regular, .footnote)).foregroundStyle(Palette.rose)
                }
            }
        }
    }

    private var demoIcons: Bool {
        #if DEBUG
        return Demo.isOn
        #else
        return false
        #endif
    }

    private var selectionSummary: String {
        var parts: [String] = []
        if !selection.applicationTokens.isEmpty { parts.append(String(localized: "\(selection.applicationTokens.count) apps")) }
        if !selection.categoryTokens.isEmpty { parts.append(String(localized: "\(selection.categoryTokens.count) categories")) }
        if !selection.webDomainTokens.isEmpty { parts.append(String(localized: "\(selection.webDomainTokens.count) websites")) }
        return parts.joined(separator: " · ")
    }

    private var websitesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow("Websites by address", color: Palette.muted)
                ForEach(plan.domains, id: \.self) { d in
                    HStack {
                        Image(systemName: "globe").foregroundStyle(Palette.faint)
                        Text(d).font(.p(16, .regular)).foregroundStyle(Palette.ink)
                        Spacer()
                        if !readOnly {
                            Button { plan.domains.removeAll { $0 == d } } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.faint)
                            }
                            .accessibilityLabel(Text("Remove \(d)"))
                        }
                    }
                }
                if plan.domains.isEmpty && readOnly {
                    Text("None.").font(.p(15, .regular)).foregroundStyle(Palette.faint)
                }
                if !readOnly {
                HStack {
                    TextField(text: $newDomain, prompt: Text("youtube.com").foregroundStyle(Palette.faint)) { Text("Website") }
                        .font(.p(16, .regular))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .onSubmit(addDomain)
                    Button("Add", action: addDomain)
                        .font(.p(15, .medium)).foregroundStyle(Palette.brass)
                        .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty || plan.domains.count >= Limits.maxDomains)
                }
                .padding(.horizontal, 14).frame(minHeight: 46)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.04)))
                if domainError {
                    Text("That doesn't look like a website address.").font(.p(13, .regular, .footnote)).foregroundStyle(Palette.rose)
                }
                }
                Text("Blocked in Safari, Chrome and other browsers. While a site is blocked, private browsing is off.")
                    .font(.p(13, .regular, .footnote)).foregroundStyle(Palette.faint)
            }
        }
    }

    private func addDomain() {
        guard let d = Domains.normalize(newDomain) else { domainError = !newDomain.isEmpty; return }
        domainError = false
        if !plan.domains.contains(d) { plan.domains.append(d) }
        newDomain = ""
    }

    private var whenCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow("When", color: Palette.muted)
                HStack {
                    timePicker("From", value: $plan.start)
                    Spacer()
                    Image(systemName: "arrow.right").foregroundStyle(Palette.faint)
                    Spacer()
                    timePicker("To", value: $plan.end)
                }
                DayChips(days: $plan.days)
                Text(windowNote).font(.p(13, .regular, .footnote)).foregroundStyle(problems.contains(.windowTooShort) || problems.contains(.windowTooLong) ? Palette.rose : Palette.faint)
            }
        }
    }

    private var windowNote: String {
        if problems.contains(.windowTooShort) { return String(localized: "A block must last at least 15 minutes.") }
        if problems.contains(.windowTooLong) { return String(localized: "A block can last at most 22 hours, so there's always time to change it between windows.") }
        let len = minutesText(ScheduleMath.length(plan.start, plan.end))
        if ScheduleMath.isOvernight(plan) { return String(localized: "\(len), overnight — it ends the next morning.") }
        return String(localized: "\(len) each selected day.")
    }

    private func timePicker(_ title: LocalizedStringKey, value: Binding<TimeOfDay>) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.p(12, .medium, .caption)).foregroundStyle(Palette.faint)
            DatePicker("", selection: Binding(get: { value.wrappedValue.date }, set: { value.wrappedValue = TimeOfDay(date: $0) }),
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.compact)
        }
    }

    private var limitCard: some View {
        Card {
            VStack(spacing: 16) {
                Eyebrow("Each day", color: Palette.muted)
                Text(minutesText(plan.limitMinutes))
                    .font(.p(48, .extraLight, .largeTitle))
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.numericText())
                if !readOnly {
                HStack(spacing: 14) {
                    stepButton("minus", delta: plan.limitMinutes > 60 ? -15 : -5)
                    stepButton("plus", delta: plan.limitMinutes >= 60 ? 15 : 5)
                }
                }
                DayChips(days: $plan.days)
                Text("When the time is used up, these apps lock until midnight. A new limit starts counting when you save it.")
                    .font(.p(13, .regular, .footnote)).foregroundStyle(Palette.faint).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func stepButton(_ icon: String, delta: Int) -> some View {
        Button {
            withAnimation { plan.limitMinutes = min(max(plan.limitMinutes + delta, Limits.limitMinutes.lowerBound), Limits.limitMinutes.upperBound) }
        } label: {
            Image(systemName: icon).font(.system(size: 18, weight: .light)).foregroundStyle(Palette.ink)
                .frame(width: 56, height: 44)
                .background(Capsule().fill(Color.white.opacity(0.05)))
                .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(delta < 0 ? "Less time" : "More time"))
    }

    private var deleteButton: some View {
        Button("Delete block", role: .destructive) { confirmDelete = true }
            .buttonStyle(GhostButton(tint: Palette.rose))
            .padding(.top, 8)
    }

    // MARK: actions

    /// End of the window that saving would start right now (nil when it wouldn't start now).
    private var startsNowUntil: Date? {
        guard plan.kind == .schedule, plan.isOn else { return nil }
        let wasRunning = existing.map { model.status($0).isBlocking } ?? false
        guard !wasRunning else { return nil }
        switch Status.of(plan, now: Date(), reachedAt: nil, calendar: .current) {
        case .running(let until): return until
        case .waiting(let next?) where next.timeIntervalSinceNow <= Engine.edge:     // starts within the minute
            return ScheduleMath.window(containing: next.addingTimeInterval(1), plan: plan, calendar: .current)?.end
        default: return nil
        }
    }

    private func save() {
        if startsNowUntil != nil { confirmStart = true } else { commitSave() }
    }

    private func commitSave() {
        let outcome = model.save(plan: plan, selection: selection, id: existing?.id)
        finish(outcome)
    }

    private func delete() {
        guard let id = existing?.id else { return }
        finish(model.delete(id))
    }

    private func finish(_ outcome: AppModel.Outcome) {
        switch outcome {
        case .saved: dismiss()
        case .scheduled(let at):
            model.toast = String(localized: "Saved. It takes effect at \(Fmt.moment(at, now: model.now)) — today's limit stays as it was.")
            dismiss()
        case .refused(let why): model.problem = why
        }
    }
}
