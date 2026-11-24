import FamilyControls
import SwiftUI

enum AppTab: Hashable { case home, blocks, settings }

/// The app once it's set up: Home, Blocks and Settings in the standard bottom tab bar (compact Liquid Glass on iOS 26
/// and later), with a small glass Block now button floating above it on Home and Blocks. On an iPad the tabs sit at the
/// top, and can become a sidebar (Apple's iPad tab bar).
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
                BlocksTab(openBlockNow: openBlockNow)
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                SettingsTab()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .sheet(isPresented: $showBlockNow) { BlockNowSheet().environmentObject(model) }
        .sheet(isPresented: $showSession) { SessionSheet().environmentObject(model) }
        #if DEBUG
        .onAppear {
            switch Demo.shot {
            case "blocknow": showBlockNow = true
            case "session-sheet": showSession = true
            case "toast": model.toast = String(localized: "Strict lock is off. Blocks running now stay strict until they reset or end.")
            default: break
            }
        }
        #endif
    }

    private func openBlockNow() {
        if model.activeSession != nil { showSession = true } else { showBlockNow = true }
    }
}

/// Block now, one tap away: a small Liquid Glass button floating above the tab bar's trailing end (a frosted
/// capsule before iOS 26). While a Block now runs it shows the time left.
struct BlockNowButton: View {
    @EnvironmentObject private var model: AppModel
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                Image(systemName: model.activeSession == nil ? "lock" : "lock.fill")
                    .font(.system(size: 15, weight: .semibold))
                if let s = model.activeSession {
                    Text(durationText(s.endsAt.timeIntervalSince(model.now))).monospacedDigit()
                } else {
                    Text("Block now")
                }
            }
            .font(.p(16, .semibold, .headline))
            .foregroundStyle(Palette.brass)
            .padding(.horizontal, 18)
            .frame(height: 48)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(GlassCapsule())
        .accessibilityLabel(Text(model.activeSession == nil ? "Block now" : "Block now is running"))
    }
}

private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            content.background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
        }
    }
}

extension View {
    /// Block now floating above the tab bar at the trailing edge, with room under the list so it never hides a row.
    func blockNowButton(_ open: @escaping () -> Void) -> some View {
        overlay(alignment: .bottomTrailing) {
            BlockNowButton(open: open).padding(.trailing, 20).padding(.bottom, 14)
        }
        .contentMargins(.bottom, 72, for: .scrollContent)
    }
}

/// A running Block now: when it ends, what it blocks, and Stop when it isn't strict.
struct SessionSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmStop = false
    /// Why Stop was refused, shown by this sheet itself (see problemAlert).
    @State private var refusal: String?
    /// The picker's choice when adding to the running Block now (it starts from what's blocked; nothing is taken out).
    @State private var adding = FamilyActivitySelection()
    @State private var showPicker = false

    var body: some View {
        NavigationStack {
            Form {
                if let s = model.activeSession {
                    Section {
                        LabeledContent("Ends") { Text(Fmt.moment(s.endsAt, now: model.now)) }
                        LabeledContent("Time left") { Text(durationText(s.endsAt.timeIntervalSince(model.now))) }
                        if !s.selection.isEmpty { TokenIcons(selection: s.selection, max: 8).padding(.vertical, 4) }
                        if !s.domains.isEmpty { LabeledContent("Websites") { Text(s.domains.joined(separator: ", ")) } }
                        Button("Add apps & websites") { adding = s.selection; showPicker = true }
                    } footer: {
                        Text("You can add apps and websites while it runs, but not take any out.")
                    }
                    .listRowBackground(Palette.card)
                    Section {
                        if model.canStopSession {
                            Button("Stop Block now", role: .destructive) { confirmStop = true }
                        }
                    } footer: {
                        Text(model.canStopSession ? "Strict lock is off for this Block now, so it can be stopped."
                             : model.lockInActive ? "You're locked in, so it can't be stopped."
                             : "This Block now has Strict lock, so it can't be stopped. It ends on its own.")
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
            .familyActivityPicker(headerText: String(localized: "Choose apps, categories and websites to add."),
                                  isPresented: $showPicker, selection: $adding)
            .onChange(of: adding) { _, picked in
                if case .refused(let why) = model.addToSession(picked) { refusal = why }
            }
            .confirmationDialog(Text("Stop Block now?"), isPresented: $confirmStop, titleVisibility: .visible) {
                Button("Stop Block now", role: .destructive) {
                    switch model.stopSession() {
                    case .refused(let why): refusal = why
                    default: model.toast = String(localized: "Block now is stopped."); dismiss()
                    }
                }
            } message: {
                Text("The apps open now.")
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Palette.night)
        .problemAlert($refusal)
    }
}
