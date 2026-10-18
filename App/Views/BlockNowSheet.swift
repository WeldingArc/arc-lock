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

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                ScrollView {
                    VStack(spacing: 18) {
                        Card {
                            VStack(alignment: .leading, spacing: 12) {
                                Eyebrow("Block", color: Palette.muted)
                                if selection.isEmpty {
                                    Text("Nothing chosen yet.").font(.p(15, .regular)).foregroundStyle(Palette.faint)
                                } else {
                                    TokenIcons(selection: selection, max: 8)
                                }
                                Button(selection.isEmpty ? "Choose apps & websites" : "Change") { showPicker = true }
                                    .buttonStyle(GhostButton(tint: Palette.brass))
                                if overCap {
                                    Text("Choose at most \(Limits.maxApps) apps and \(Limits.maxDomains) websites — or pick whole categories instead.")
                                        .font(.p(13, .regular, .footnote)).foregroundStyle(Palette.rose)
                                }
                            }
                        }
                        websitesCard
                        Card {
                            VStack(spacing: 16) {
                                Eyebrow("For", color: Palette.muted)
                                Text(minutesText(minutes))
                                    .font(.p(48, .extraLight, .largeTitle))
                                    .foregroundStyle(Palette.ink)
                                    .contentTransition(.numericText())
                                HStack(spacing: 8) {
                                    ForEach(presets, id: \.self) { m in
                                        Button { withAnimation { minutes = m } } label: {
                                            Text(minutesText(m))
                                                .font(.p(13, minutes == m ? .semibold : .regular))
                                                .foregroundStyle(minutes == m ? Palette.night : Palette.muted)
                                                .frame(maxWidth: .infinity, minHeight: 36)
                                                .background(Capsule().fill(minutes == m ? Palette.brass : Palette.wash(0.04)))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                Slider(value: Binding(get: { Double(minutes) }, set: { minutes = Int($0 / 15).clamped(1, 48) * 15 }),
                                       in: 15...720, step: 15)
                                Text("Ends at \(Fmt.moment(model.now.addingTimeInterval(TimeInterval(minutes * 60)), now: model.now)).")
                                    .font(.p(14, .regular)).foregroundStyle(Palette.muted)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle(isOn: $strict) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Strict lock").font(.p(17, .medium)).foregroundStyle(Palette.ink)
                                        Text(strict ? "Once it starts, it can't be stopped." : "You can stop it from Home any time.")
                                            .font(.p(13, .regular, .footnote)).foregroundStyle(Palette.faint)
                                    }
                                }
                                .tint(Palette.brass)
                                if strict && !model.strictLockActive {
                                    Text("Strict lock is off in Settings, so for now it can be stopped.")
                                        .font(.p(13, .regular, .footnote)).foregroundStyle(Palette.rose)
                                }
                            }
                        }
                        Button("Start") { confirm = true }
                            .buttonStyle(BrassButton())
                            .disabled(nothingChosen || overCap)
                            .opacity(nothingChosen || overCap ? 0.5 : 1)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle(Text("Block now"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.foregroundStyle(Palette.muted) }
            }
            .familyActivityPicker(headerText: String(localized: "Choose what to block right now."), isPresented: $showPicker, selection: $selection)
            .confirmationDialog(Text("Block for \(minutesText(minutes))?"), isPresented: $confirm, titleVisibility: .visible) {
                Button(stoppable ? "Start" : "Start — can't be stopped") { start() }
            } message: {
                Text("Locked until \(Fmt.moment(model.now.addingTimeInterval(TimeInterval(minutes * 60)), now: model.now)).")
            }
        }
        .presentationBackground(Palette.night)
        .onAppear {
            if let last = model.state.lastSessionSelection { selection = last }
            minutes = model.state.lastSessionMinutes
        }
    }

    private func start() {
        switch model.startSession(selection: selection, domains: domains, minutes: minutes, strict: strict) {
        case .refused(let why): model.problem = why
        default: dismiss()
        }
    }
}

extension BlockNowSheet {
    /// Typed addresses go through iOS's web filter, so they're blocked in every browser (picked websites: Safari only).
    fileprivate var websitesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow("Websites by address", color: Palette.muted)
                ForEach(domains, id: \.self) { d in
                    HStack {
                        Image(systemName: "globe").foregroundStyle(Palette.faint)
                        Text(d).font(.p(16, .regular)).foregroundStyle(Palette.ink)
                        Spacer()
                        Button { domains.removeAll { $0 == d } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.faint)
                        }
                        .accessibilityLabel(Text("Remove \(d)"))
                    }
                }
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
                        .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty || domains.count >= Limits.maxDomains)
                }
                .padding(.horizontal, 14).frame(minHeight: 46)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.wash(0.04)))
                if domainError {
                    Text("That doesn't look like a website address.").font(.p(13, .regular, .footnote)).foregroundStyle(Palette.rose)
                }
                Text("Blocked in Safari and every other browser while Block now runs.")
                    .font(.p(13, .regular, .footnote)).foregroundStyle(Palette.faint)
            }
        }
    }

    fileprivate func addDomain() {
        guard let d = Domains.normalize(newDomain) else { domainError = !newDomain.isEmpty; return }
        domainError = false
        if !domains.contains(d) { domains.append(d) }
        newDomain = ""
    }
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}
