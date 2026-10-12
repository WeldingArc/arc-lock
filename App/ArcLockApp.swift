import SwiftUI

@main
struct ArcLockApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .tint(Palette.brass)
                .onChange(of: phase) { _, p in
                    if p == .active { model.refresh(); Task { await model.checkAccess() } }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Backdrop()
            if !model.state.onboarded {
                OnboardingView()
                    .transition(.opacity)
            } else if !model.authChecked && !model.isAuthorized {
                ArcMark(size: 84)          // a moment while iOS confirms access
            } else if !model.isAuthorized {
                AccessOffView()
            } else {
                HomeView()
            }
        }
        .animation(.easeInOut(duration: 0.35), value: model.state.onboarded)
        .alert(String(localized: "Arc Lock"), isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.problem ?? "")
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t)
                    .font(.p(15, .regular, .callout))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(Capsule().fill(Palette.cardHi))
                    .overlay(Capsule().strokeBorder(Palette.brass.opacity(0.35), lineWidth: 1))
                    .padding(.horizontal, 24).padding(.bottom, 28)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: t) {
                        try? await Task.sleep(for: .seconds(3.2))
                        withAnimation { model.toast = nil }
                    }
            }
        }
        .animation(.spring(duration: 0.35), value: model.toast)
    }
}

/// Shown when Screen Time access was turned off in Settings (or never granted).
struct AccessOffView: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ArcMark(size: 84, locked: false)
            Text("Screen Time access is off")
                .font(.p(28, .light, .title))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            Text("Arc Lock blocks apps through Apple's Screen Time. Without access, none of your blocks can run.")
                .font(.p(16, .regular))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Allow Screen Time access") { Task { _ = await model.requestScreenTime() } }
                .buttonStyle(BrassButton())
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
    }
}
