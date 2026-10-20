import FamilyControls
import SwiftUI

/// Block chosen apps right away for a fixed time. With Strict lock (the default) it can't be stopped once started.
struct BlockNowSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection = FamilyActivitySelection()
    @State private var minutes = 60
    @State private var showPicker = false
    @State private var confirm = false
    @State private var strict = true
    @State private var domains: [String] = []
    @State private var newDomain = ""
    @State private var domainError = false
    private var nothingChosen: Bool { selection.isEmpty && domains.isEmpty }
    private var stoppable: Bool { !strict || !model.strictLockActive }
    private let presets = [15, 30, 60, 120, 240]
    private var overCap: Bool {
        selection.applicationTokens.count > Limits.maxApps || selection.webDomainTokens.count > Limits.maxDomains
    }
    private var endsAt: Date { model.now.addingTimeInterval(TimeInterval(minutes * 60)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if selection.isEmpty {
                        Text("Nothing chosen yet.").foregroundStyle(Palette.faint)
                    } else {
                        TokenIcons(selection: selection, max: 8).padding(.vertical, 4)
                    }
                    Button(selection.isEmpty ? "Choose apps & websites" : "Change") { showPicker = true }
                } header: {
                    Text("Block")
                } footer: {
                    if overCap {
                        Text("Choose at most \(Limits.maxApps) apps and \(Limits.maxDomains) websites — or pick whole categories instead.")
                            .foregroundStyle(Palette.rose)
                    }
                }
                .listRowBackground(Palette.card)

                websitesSection

                Section {
                    Picker("Length", selection: $minutes) {
                        ForEach(presets, id: \.self) { m in Text(minutesText(m)).tag(m) }
                        if !presets.contains(minutes) { Text(minutesText(minutes)).tag(minutes) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Slider(value: Binding(get: { Double(minutes) }, set: { minutes = Int($0 / 15).clamped(1, 48) * 15 }),
                           in: 15...720, step: 15)
                    LabeledContent("Ends") { Text(Fmt.moment(endsAt, now: model.now)) }
                } header: {
                    Text("For \(minutesText(minutes))")
                }
                .listRowBackground(Palette.card)

                Section {
                    Toggle("Strict lock", isOn: $strict)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(strict ? "Once it starts, it can't be stopped." : "You can stop it any time.")
                        if strict && !model.strictLockActive {
                            Text("Strict lock is off in Settings, so for now it can be stopped.").foregroundStyle(Palette.rose)
                        }
                    }
                }
                .listRowBackground(Palette.card)

                Section {
                    Button { confirm = true } label: {
                        Text("Start").fontWeight(.semibold).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(nothingChosen || overCap)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .themedList()
            .navigationTitle(Text("Block now"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .familyActivityPicker(headerText: String(localized: "Choose what to block right now."), isPresented: $showPicker, selection: $selection)
            .confirmationDialog(Text("Block for \(minutesText(minutes))?"), isPresented: $confirm, titleVisibility: .visible) {
                Button(stoppable ? "Start" : "Start — can't be stopped") { start() }
            } message: {
                Text("Locked until \(Fmt.moment(endsAt, now: model.now)).")
            }
        }
        .presentationBackground(Palette.night)
        .onAppear {
            if let last = model.state.lastSessionSelection { selection = last }
            minutes = model.state.lastSessionMinutes
        }
    }

    /// Typed addresses go through iOS's web filter, so they're blocked in every browser (picked websites: Safari only).
    private var websitesSection: some View {
        Section {
            ForEach(domains, id: \.self) { d in
                Label(d, systemImage: "globe")
                    .swipeActions {
                        Button(role: .destructive) { domains.removeAll { $0 == d } } label: { Label("Remove", systemImage: "trash") }
                    }
            }
            HStack {
                TextField("Website", text: $newDomain, prompt: Text("youtube.com"))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .onSubmit(addDomain)
                Button("Add", action: addDomain)
                    .buttonStyle(.borderless)
                    .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty || domains.count >= Limits.maxDomains)
            }
        } header: {
            Text("Websites by address")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if domainError { Text("That doesn't look like a website address.").foregroundStyle(Palette.rose) }
                Text("Blocked in Safari and every other browser while Block now runs.")
            }
        }
        .listRowBackground(Palette.card)
    }

    private func addDomain() {
        guard let d = Domains.normalize(newDomain) else { domainError = !newDomain.isEmpty; return }
        domainError = false
        if !domains.contains(d) { domains.append(d) }
        newDomain = ""
    }

    private func start() {
        switch model.startSession(selection: selection, domains: domains, minutes: minutes, strict: strict) {
        case .refused(let why): model.problem = why
        default: dismiss()
        }
    }
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}
