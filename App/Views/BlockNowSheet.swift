import FamilyControls
import SwiftUI

/// Block chosen apps right away for a fixed time. Once started it can't be stopped.
struct BlockNowSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection = FamilyActivitySelection()
    @State private var minutes = 60
    @State private var showPicker = false
    @State private var confirm = false
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
                                                .background(Capsule().fill(minutes == m ? Palette.brass : Color.white.opacity(0.04)))
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
                        Text("Once it starts, it can't be stopped from Arc Lock, by deleting apps, or by changing the clock.")
                            .font(.p(13, .regular, .footnote)).foregroundStyle(Palette.faint).multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                        Button("Start") { confirm = true }
                            .buttonStyle(BrassButton())
                            .disabled(selection.isEmpty || overCap)
                            .opacity(selection.isEmpty || overCap ? 0.5 : 1)
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
                Button("Start — can't be stopped") { start() }
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
        switch model.startSession(selection: selection, domains: [], minutes: minutes) {
        case .refused(let why): model.problem = why
        default: dismiss()
        }
    }
}

extension Int {
    func clamped(_ lo: Int, _ hi: Int) -> Int { Swift.min(Swift.max(self, lo), hi) }
}
