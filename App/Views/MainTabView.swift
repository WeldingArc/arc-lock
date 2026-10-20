import SwiftUI

enum AppTab: Hashable { case home, blocks, settings }

/// The app once it's set up: Home, Blocks and Settings in the bottom tab bar (Liquid Glass on iOS 26 and later),
/// with Block now in a glass bar just above the tabs, one tap away from anywhere.
struct MainTabView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showBlockNow = false
    @State private var showSession = false

    var body: some View {
        TabView(selection: $model.tab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                HomeTab(openBlockNow: openBlockNow)
            }
            Tab("Blocks", systemImage: "square.stack", value: AppTab.blocks) {
                BlocksTab()
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsTab()
            }
        }
        .modifier(BlockNowAccessory(open: openBlockNow))
        .sheet(isPresented: $showBlockNow) { BlockNowSheet().environmentObject(model) }
        .sheet(isPresented: $showSession) { SessionSheet().environmentObject(model) }
        #if DEBUG
        .onAppear {
            switch Demo.shot {
            case "blocknow": showBlockNow = true
            case "session-sheet": showSession = true
            default: break
            }
        }
        #endif
    }

    private func openBlockNow() {
        if model.activeSession != nil { showSession = true } else { showBlockNow = true }
    }
}

/// iOS 26 and later: Block now sits in a Liquid Glass bar above the tabs. Earlier iOS has no such bar, so Home shows
/// a Block now button instead (HomeTab).
private struct BlockNowAccessory: ViewModifier {
    let open: () -> Void
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .tabViewBottomAccessory { BlockNowBar(open: open) }
                .tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}

@available(iOS 26.0, *)
private struct BlockNowBar: View {
    @EnvironmentObject private var model: AppModel
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: model.activeSession == nil ? "lock" : "lock.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.brass)
                if let s = model.activeSession {
                    Text("Block now").font(.p(16, .semibold, .headline))
                    Text("\(durationText(s.endsAt.timeIntervalSince(model.now))) left")
                        .font(.p(15, .regular, .subheadline)).foregroundStyle(.secondary)
                } else {
                    Text("Block now").font(.p(16, .semibold, .headline))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(model.activeSession == nil ? "Block now" : "Block now is running"))
    }
}

/// A running Block now: when it ends, what it blocks, and Stop when it isn't strict.
struct SessionSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmStop = false

    var body: some View {
        NavigationStack {
            Form {
                if let s = model.activeSession {
                    Section {
                        LabeledContent("Ends") { Text(Fmt.moment(s.endsAt, now: model.now)) }
                        LabeledContent("Time left") { Text(durationText(s.endsAt.timeIntervalSince(model.now))) }
                        if !s.selection.isEmpty { TokenIcons(selection: s.selection, max: 8).padding(.vertical, 4) }
                        if !s.domains.isEmpty { LabeledContent("Websites") { Text(s.domains.joined(separator: ", ")) } }
                    }
                    .listRowBackground(Palette.card)
                    Section {
                        if model.canStopSession {
                            Button("Stop Block now", role: .destructive) { confirmStop = true }
                        }
                    } footer: {
                        Text(model.canStopSession ? "Strict lock is off for this Block now, so it can be stopped."
                                                  : "Strict lock is on, so it can't be stopped. It ends on its own.")
                    }
                    .listRowBackground(Palette.card)
                } else {
                    Section { Text("Block now isn't running.").foregroundStyle(.secondary) }
                        .listRowBackground(Palette.card)
                }
            }
            .themedList()
            .navigationTitle("Block now")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog(Text("Stop Block now?"), isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop Block now", role: .destructive) {
                    switch model.stopSession() {
                    case .refused(let why): model.problem = why
                    default: model.toast = String(localized: "Block now is stopped."); dismiss()
                    }
                }
            } message: {
                Text("The apps open now.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.night)
    }
}
