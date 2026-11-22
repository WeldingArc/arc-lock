import SwiftUI

@main
struct ArcLockApp: App {
    @UIApplicationDelegateAdaptor(LaunchDelegate.self) private var launch
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onChange(of: phase) { _, p in
                    if p == .active { model.didBecomeActive(); Task { await model.checkAccess() } }
                }
        }
    }
}

/// iOS relaunches Arc Lock in the background when you arrive at or leave a place block's place, and hands that to the
/// location delegate — which has to exist before launch finishes, whether or not a window ever opens.
final class LaunchDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if DEBUG
        if Demo.isOn { return true }
        #endif
        PlaceWatcher.shared.start()
        return true
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(ArcTheme.key, store: AppGroup.defaults) private var themeRaw = ArcTheme.navy.rawValue
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ZStack {
            Group {
                Backdrop()
                if model.needsRelaunch {
                    RelaunchView()
                } else if !model.state.onboarded {
                    OnboardingView()
                        .transition(.opacity)
                } else if !model.authChecked && !model.isAuthorized {
                    ArcMark(size: 84)          // a moment while iOS confirms access
                } else if !model.isAuthorized {
                    AccessOffView()
                } else {
                    MainTabView()
                }
            }
            // a new theme or text size redraws every screen (the chosen tab is kept in the model)
            .id("\(themeRaw)|\(typeSize)")
        }
        .preferredColorScheme(ArcTheme(rawValue: themeRaw)?.isLight == true ? .light : .dark)
        .tint(Palette.brass)
        .animation(.easeInOut(duration: 0.35), value: model.state.onboarded)
        .problemAlert($model.problem)
        // a short message at the top: at the bottom it covered the tab bar and Block now (and took their taps)
        .overlay(alignment: .top) {
            if let t = model.toast {
                Text(t)
                    .font(.p(15, .regular, .callout))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(Capsule().fill(Palette.cardHi))
                    .overlay(Capsule().strokeBorder(Palette.brass.opacity(0.35), lineWidth: 1))
                    .padding(.horizontal, 24).padding(.top, 6)
                    .allowsHitTesting(false)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: t) {
                        // a newer message replaces this one: its own timer then clears it, not this one
                        do { try await Task.sleep(for: .seconds(3.2)) } catch { return }
                        withAnimation { model.toast = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.35), value: model.toast)
    }
}

/// After a restart, iOS can hand a running Arc Lock its saved blocks as empty until it's opened afresh (see
/// AppModel.needsRelaunch). Instead of setup — which couldn't finish — say what to do.
struct RelaunchView: View {
    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 22) { Spacer(); words; Spacer() }
            ScrollView { words.padding(.vertical, 24) }          // very large text
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
    }

    private var words: some View {
        VStack(spacing: 22) {
            ArcMark(size: 84)
            Text("Close and reopen Arc Lock")
                .font(.p(28, .light, .title))
                .foregroundStyle(Palette.ink)
            Text("After a restart, iOS hasn't handed Arc Lock your blocks yet. They're safe. Close Arc Lock in the app switcher, then open it again.")
                .font(.p(16, .regular))
                .foregroundStyle(Palette.muted)
        }
    }
}

extension View {
    /// Arc Lock's error alert. A sheet shows its own (with its own state): an alert from the screen underneath
    /// first closes the sheet, losing what was typed in it.
    func problemAlert(_ problem: Binding<String?>) -> some View {
        alert(String(localized: "Arc Lock"), isPresented: Binding(get: { problem.wrappedValue != nil },
                                                                  set: { if !$0 { problem.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem.wrappedValue ?? "")
        }
    }
}

/// Shown when Screen Time access was turned off in Settings (or never granted). Like setup, Continue never waits on
/// iOS's answer: it shows that it's asking, looks for the access itself and works again when iOS's sheet closes.
struct AccessOffView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var asking = false
    var body: some View {
        ViewThatFits(in: .vertical) {
            VStack(spacing: 22) { Spacer(); words; Spacer(); button }
            // very large text: the words scroll and the button stays on screen
            ScrollView { words.padding(.vertical, 24) }
                .safeAreaInset(edge: .bottom) { button.padding(.top, 12).background(Palette.night) }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        // back from iOS's sheet (or Settings): the button works again, and access granted there shows at once
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            asking = false
            model.recheckScreenTime()
        }
    }

    private var words: some View {
        VStack(spacing: 22) {
            ArcMark(size: 84, locked: false)
            Text("Screen Time access is off")
                .font(.p(28, .light, .title))
                .foregroundStyle(Palette.ink)
            Text("Arc Lock blocks apps through Apple's Screen Time. Without access, none of your blocks can run.")
                .font(.p(16, .regular))
                .foregroundStyle(Palette.muted)
        }
    }

    private var button: some View {
        Button {
            asking = true
            Task {
                _ = await model.requestScreenTime()
                asking = false
            }
            // iOS's answer can arrive without the request ever returning (as on iPad): look for it meanwhile,
            // and never leave the button waiting for long
            Task {
                for _ in 0..<24 {
                    try? await Task.sleep(for: .milliseconds(500))
                    if model.recheckScreenTime() { break }
                }
                asking = false
            }
        } label: {
            if asking { ProgressView().tint(Palette.night) } else { Text("Continue") }
        }
        .buttonStyle(BrassButton())
        .disabled(asking)
        .opacity(asking ? 0.6 : 1)
    }
}
