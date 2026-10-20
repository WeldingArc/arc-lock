import FamilyControls
import SwiftUI

/// Create or change a schedule, a daily limit or a time-out. What may be changed follows the lock policy:
/// a Strict-lock block is read-only while it runs (or during a lock-in), and looser changes to a counting
/// limit or time-out wait until its next reset. A block without Strict lock can always be changed.
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
            Form {
                lockNotice            // stays tappable: undoing a waiting change is always allowed
                Group {
                    if existing == nil { kindSection }
                    nameSection
                    appsSection
                    websitesSection
                    switch plan.kind {
                    case .schedule: whenSection
                    case .limit: limitSection
                    case .timeout: timeoutSection
                    }
                    strictSection
                    if existing != nil && !readOnly { deleteSection }
                }
                .disabled(readOnly)
            }
            .themedList()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(existing == nil ? newTitle : plan.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(readOnly ? "Close" : "Cancel") { dismiss() }
                }
                if !readOnly {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { save() }.fontWeight(.semibold).disabled(!problems.isEmpty)
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
                    Text("It keeps working until \(Fmt.moment(from, now: model.now)) and is deleted then.")
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
                            days: kind == .schedule ? [2, 3, 4, 5, 6] : Set(1...7), limitMinutes: kind == .timeout ? 20 : 30)
        }
    }

    private var newTitle: String {
        switch plan.kind {
        case .schedule: String(localized: "New schedule")
        case .limit: String(localized: "New daily limit")
        case .timeout: String(localized: "New time-out")
        }
    }

    // MARK: sections

    @ViewBuilder private var lockNotice: some View {
        switch access {
        case .locked(let until, let reason):
            notice("lock.fill", AppModel.lockedMessage(until: until, reason: reason, now: model.now))
        case .stricterOnly(let from) where plan.kind == .timeout:
            notice("clock.arrow.circlepath",
                   String(localized: "This time-out is locked in until it resets. A longer break or more days apply now; any other change — the minutes of use, the apps, a shorter break, the reset time, deleting — starts at \(Fmt.moment(from, now: model.now))."))
        case .stricterOnly(let from):
            notice("clock.arrow.circlepath",
                   String(localized: "This limit is locked in until it resets. One stricter change applies now; anything else — more time, fewer apps or days, the reset time, deleting, or a second change — starts at \(Fmt.moment(from, now: model.now))."))
        case .free:
            EmptyView()
        }
        if let r = existing, let p = r.pending {
            Section {
                Text(p.plan == nil ? "This block will be deleted at \(Fmt.moment(model.effectiveDate(p, plan: r.plan), now: model.now))."
                                   : "Changes are waiting until \(Fmt.moment(model.effectiveDate(p, plan: r.plan), now: model.now)). Until then the current version runs.")
                    .foregroundStyle(Palette.muted)
                Button("Keep the current version") {
                    if let id = existing?.id { model.cancelPending(id); dismiss() }
                }
            }
            .listRowBackground(Palette.card)
        }
    }

    private func notice(_ icon: String, _ text: String) -> some View {
        Section {
            Label { Text(text).foregroundStyle(Palette.ink) } icon: { Image(systemName: icon).foregroundStyle(Palette.brass) }
                .font(.p(15, .regular, .subheadline))
        }
        .listRowBackground(Palette.cardHi)
    }

    private var kindSection: some View {
        Section {
            Picker("Kind", selection: Binding(get: { plan.kind }, set: { k in
                let was = plan.kind
                plan.kind = k
                if k != .schedule && plan.days == [2, 3, 4, 5, 6] { plan.days = Set(1...7) }
                if k == .timeout && was != .timeout { plan.limitMinutes = 20 }
                if k == .limit && was == .timeout { plan.limitMinutes = 30 }
            })) {
                Text("Schedule").tag(RuleKind.schedule)
                Text("Daily limit").tag(RuleKind.limit)
                Text("Time-out").tag(RuleKind.timeout)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private var nameSection: some View {
        Section("Name") {
            TextField("Name", text: $plan.name,
                      prompt: Text(plan.kind == .schedule ? "Study, Sleep, Work…" : (plan.kind == .timeout ? "Shorts, Reels, Games…" : "Social, Games, Video…")))
                .submitLabel(.done)
        }
        .listRowBackground(Palette.card)
    }

    private var appsSection: some View {
        Section {
            if selection.isEmpty && !demoIcons {
                Text("Nothing chosen yet.").foregroundStyle(Palette.faint)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    TokenIcons(selection: selection, max: 8, demoName: plan.name)
                    if !selection.isEmpty { Text(selectionSummary).font(.p(14, .regular, .subheadline)).foregroundStyle(Palette.muted) }
                }
                .padding(.vertical, 4)
            }
            if !readOnly {
                Button(selection.isEmpty ? "Choose apps & websites" : "Change") { showPicker = true }
            }
        } header: {
            Text("Apps & websites")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if plan.kind.countsUse {
                    Text(plan.kind == .limit ? "Time in these apps and websites adds up toward one daily limit."
                                             : "Time in these apps and websites adds up toward each break.")
                    Text("Website time counts in Safari and in browsers that share it with Screen Time (turn that on in the browser's settings).")
                } else if !selection.webDomainTokens.isEmpty {
                    Text("Websites picked here are blocked in Safari. To block a site in every browser, also add it by address below.")
                }
                if selection.webDomainTokens.count > Limits.maxDomains {
                    Text("Choose at most \(Limits.maxDomains) websites.").foregroundStyle(Palette.rose)
                }
                if selection.applicationTokens.count > Limits.maxApps {
                    Text("Choose at most \(Limits.maxApps) apps — or pick a whole category instead.").foregroundStyle(Palette.rose)
                }
            }
        }
        .listRowBackground(Palette.card)
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

    private var websitesSection: some View {
        Section {
            ForEach(plan.domains, id: \.self) { d in
                Label(d, systemImage: "globe")
                    .swipeActions {
                        if !readOnly {
                            Button(role: .destructive) { plan.domains.removeAll { $0 == d } } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
            }
            if plan.domains.isEmpty && readOnly {
                Text("None.").foregroundStyle(Palette.faint)
            }
            if !readOnly {
                HStack {
                    TextField("Website", text: $newDomain, prompt: Text("youtube.com"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.done)
                        .onSubmit(addDomain)
                    Button("Add", action: addDomain)
                        .buttonStyle(.borderless)
                        .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty || plan.domains.count >= Limits.maxDomains)
                }
            }
        } header: {
            Text("Websites by address")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if domainError { Text("That doesn't look like a website address.").foregroundStyle(Palette.rose) }
                Text(websitesNote)
            }
        }
        .listRowBackground(Palette.card)
    }

    private var websitesNote: String {
        switch plan.kind {
        case .schedule: String(localized: "Blocked in Safari and every other browser. While a site is blocked, private browsing is off.")
        case .limit: String(localized: "Blocked in every browser once the time is used up. To count time on a site, also pick it above.")
        case .timeout: String(localized: "Blocked in every browser during each break. To count time on a site, also pick it above.")
        }
    }

    private func addDomain() {
        guard let d = Domains.normalize(newDomain) else { domainError = !newDomain.isEmpty; return }
        domainError = false
        if !plan.domains.contains(d) { plan.domains.append(d) }
        newDomain = ""
    }

    private var whenSection: some View {
        Section {
            timePicker("From", value: $plan.start)
            timePicker("To", value: $plan.end)
            DayChips(days: $plan.days).padding(.vertical, 4)
        } header: {
            Text("When")
        } footer: {
            Text(windowNote).foregroundStyle(problems.contains(.windowTooShort) || problems.contains(.windowTooLong) ? Palette.rose : Palette.muted)
        }
        .listRowBackground(Palette.card)
    }

    private var windowNote: String {
        if problems.contains(.windowTooShort) { return String(localized: "A block must last at least 15 minutes.") }
        if problems.contains(.windowTooLong) { return String(localized: "A block can last at most 22 hours, so there's always time to change it between windows.") }
        let len = minutesText(ScheduleMath.length(plan.start, plan.end))
        if ScheduleMath.isOvernight(plan) { return String(localized: "\(len), overnight — it ends the next morning.") }
        return String(localized: "\(len) each selected day.")
    }

    private func timePicker(_ title: LocalizedStringKey, value: Binding<TimeOfDay>) -> some View {
        DatePicker(title, selection: Binding(get: { value.wrappedValue.date }, set: { value.wrappedValue = TimeOfDay(date: $0) }),
                   displayedComponents: .hourAndMinute)
    }

    private var limitSection: some View {
        Section {
            Stepper {
                LabeledContent("Each day") { Text(minutesText(plan.limitMinutes)).foregroundStyle(Palette.ink).monospacedDigit() }
            } onIncrement: {
                step(&plan.limitMinutes, by: plan.limitMinutes >= 60 ? 15 : 5, in: Limits.limitMinutes)
            } onDecrement: {
                step(&plan.limitMinutes, by: plan.limitMinutes > 60 ? -15 : -5, in: Limits.limitMinutes)
            }
            timePicker("Resets at", value: $plan.resetAt)
            DayChips(days: $plan.days).padding(.vertical, 4)
        } header: {
            Text("Daily limit")
        } footer: {
            Text("When the time is used up, these apps lock until \(resetText). A new limit starts counting when you save it.")
        }
        .listRowBackground(Palette.card)
    }

    private var timeoutSection: some View {
        Section {
            Stepper {
                LabeledContent("After this much use") { Text(minutesText(plan.limitMinutes)).foregroundStyle(Palette.ink).monospacedDigit() }
            } onIncrement: {
                step(&plan.limitMinutes, by: plan.limitMinutes >= 60 ? 15 : 5, in: Limits.timeoutUseMinutes)
            } onDecrement: {
                step(&plan.limitMinutes, by: plan.limitMinutes > 60 ? -15 : -5, in: Limits.timeoutUseMinutes)
            }
            Stepper {
                LabeledContent("Take a break of") { Text(minutesText(plan.breakMinutes)).foregroundStyle(Palette.ink).monospacedDigit() }
            } onIncrement: {
                step(&plan.breakMinutes, by: breakStep(down: false), in: Limits.breakMinutes)
            } onDecrement: {
                step(&plan.breakMinutes, by: -breakStep(down: true), in: Limits.breakMinutes)
            }
            timePicker("Resets at", value: $plan.resetAt)
            DayChips(days: $plan.days).padding(.vertical, 4)
        } header: {
            Text("Time-out")
        } footer: {
            Text("After \(minutesText(plan.limitMinutes)) of use, these apps lock for \(minutesText(plan.breakMinutes)). Then they open again and the count starts over. It all starts fresh at \(resetText).")
        }
        .listRowBackground(Palette.card)
    }

    /// "midnight" or "4:00 AM".
    private var resetText: String {
        plan.resetAt == .midnight ? String(localized: "midnight") : plan.resetAt.text
    }

    private func step(_ value: inout Int, by delta: Int, in range: ClosedRange<Int>) {
        value = min(max(value + delta, range.lowerBound), range.upperBound)
    }

    /// 1-minute steps for short breaks, 5 up to an hour, then 15.
    private func breakStep(down: Bool) -> Int {
        let m = plan.breakMinutes
        if down { return m > 60 ? 15 : (m > 10 ? 5 : 1) }
        return m >= 60 ? 15 : (m >= 10 ? 5 : 1)
    }

    private var strictSection: some View {
        Section {
            Toggle("Strict lock", isOn: $plan.strict)
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(plan.strict ? "While it runs, it can't be stopped, loosened or deleted." : "You can stop it or change it any time.")
                if plan.strict && !model.state.strictLock {
                    Text(plan.kind.countsUse ? "Strict lock is off in Settings, so this block can be stopped after its next reset."
                                             : "Strict lock is off in Settings, so for now this block can be stopped.")
                        .foregroundStyle(Palette.rose)
                }
            }
        }
        .listRowBackground(Palette.card)
    }

    private var deleteSection: some View {
        Section {
            Button("Delete block", role: .destructive) { confirmDelete = true }
        }
        .listRowBackground(Palette.card)
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
        finish(model.save(plan: plan, selection: selection, id: existing?.id))
    }

    private func delete() {
        guard let id = existing?.id else { return }
        finish(model.delete(id))
    }

    private func finish(_ outcome: AppModel.Outcome) {
        switch outcome {
        case .saved: dismiss()
        case .scheduled(let at):
            model.toast = String(localized: "Saved. It takes effect at \(Fmt.moment(at, now: model.now)). Until then the current version runs.")
            dismiss()
        case .refused(let why): model.problem = why
        }
    }
}
