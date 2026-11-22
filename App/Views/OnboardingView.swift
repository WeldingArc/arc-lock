import SwiftUI

/// First run: what Arc Lock does, then Screen Time access (required) and notifications (optional). Each permission
/// screen only explains and continues to iOS's own request, where the choice is made (App Review 5.1.1(iv)).
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var asking = false
    /// The page, kept in the model: a new text size redraws every screen, and setup must stay where it was.
    private var page: Int {
        get { model.setupPage }
        nonmutating set { model.setupPage = newValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            // moves only with its buttons: a swipe could skip Screen Time access
            ZStack {
                Group {
                    switch page {
                    case 0: welcome
                    case 1: how
                    case 2: access
                    default: notifications
                    }
                }
                .id(page)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .animation(.easeInOut(duration: 0.35), value: page)
            // access granted (iOS's answer can arrive without the request ever returning, as on iPad): go on
            .onChange(of: model.isAuthorized) { _, granted in
                if granted && page == 2 { asking = false; page = 3 }
            }
            // back from iOS's Screen Time sheet (or Settings): the button works again; go on if access was granted
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, page == 2, !isDemo else { return }
                asking = false
                if model.recheckScreenTime() { page = 3 } else { watchForAccess(seconds: 4) }
            }
            #if DEBUG
            .onAppear {
                if Demo.shot == "onboarding-how" { page = 1 }
                if Demo.shot == "onboarding-access" { page = 2 }
                if Demo.shot == "onboarding-notifications" { page = 3 }
            }
            #endif
            dots.padding(.bottom, 18)
        }
    }

    /// Demo screenshots stay on the page they ask for (demo access always counts as granted).
    private var isDemo: Bool {
        #if DEBUG
        return Demo.isOn
        #else
        return false
        #endif
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(i == page ? Palette.brass : Palette.line).frame(width: i == page ? 18 : 6, height: 6)
            }
        }
        .animation(.spring(duration: 0.3), value: page)
        .accessibilityHidden(true)
    }

    private func screen<Content: View>(@ViewBuilder content: () -> Content, button: LocalizedStringKey,
                                       secondary: LocalizedStringKey? = nil, waits: Bool = false, action: @escaping () -> Void,
                                       secondaryAction: (() -> Void)? = nil) -> some View {
        let buttons = VStack(spacing: 22) {
            Button(action: action) {
                // while iOS is asking, show that it's waiting (the button works again once iOS's sheet closes)
                if waits && asking { ProgressView().tint(Palette.night) } else { Text(button) }
            }
            .buttonStyle(BrassButton())
            .disabled(waits && asking)
            .opacity(waits && asking ? 0.6 : 1)
            if let secondary, let secondaryAction {
                Button(secondary, action: secondaryAction).font(.p(16, .regular)).foregroundStyle(Palette.muted).frame(minHeight: 44)
            }
        }
        return ViewThatFits(in: .vertical) {
            // the page as designed, when it fits
            VStack(spacing: 22) {
                Spacer(minLength: 20)
                content()
                Spacer(minLength: 20)
                buttons
            }
            // very large text: the words scroll and the button stays on screen
            ScrollView {
                VStack(spacing: 22) { content() }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) {
                buttons
                    .padding(.top, 18)
                    .frame(maxWidth: .infinity)
                    // the words scrolled under the button fade out instead of showing through
                    .background(LinearGradient(colors: [Palette.night.opacity(0), Palette.night],
                                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.3)))
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
    }

    private var welcome: some View {
        screen(content: {
            ArcMark(size: 112)
            Text("Arc Lock").font(.p(46, .extraLight, .largeTitle)).foregroundStyle(Palette.ink)
            Text("Blocks you can't break.").font(.p(20, .light, .title3)).foregroundStyle(Palette.brass)
            Text("Free, no account, no ads. Everything stays on this iPhone.")
                .font(.p(15, .regular)).foregroundStyle(Palette.muted)
        }, button: "Continue", action: { page = 1 })
    }

    private var how: some View {
        screen(content: {
            Eyebrow("How it works")
            VStack(spacing: 26) {
                feature("calendar.badge.clock", "Schedules", "Pick apps and websites and the hours they stay locked.")
                feature("hourglass", "Daily limits", "After the time you allow, they lock until the limit resets.")
                feature("cup.and.saucer", "Time-outs", "After a stretch of use, a short break. Then they open again.")
                feature("lock.fill", "Strict lock", "A strict block can't be stopped while it runs, and Arc Lock can't be deleted.")
            }
            .padding(.top, 8)
        }, button: "Continue", action: { page = 2 })
    }

    private func feature(_ icon: String, _ title: LocalizedStringKey, _ text: LocalizedStringKey) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 24, weight: .light)).foregroundStyle(Palette.brass)
            Text(title).font(.p(19, .regular, .title3)).foregroundStyle(Palette.ink)
            Text(text).font(.p(15, .regular)).foregroundStyle(Palette.muted)
        }
    }

    private var access: some View {
        screen(content: {
            Image(systemName: "hourglass.circle").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(Palette.brass)
            Text("Screen Time access").font(.p(30, .light, .title)).foregroundStyle(Palette.ink)
            Text("Arc Lock blocks apps through Apple's Screen Time. iOS will ask for your Face ID or passcode.")
                .font(.p(16, .regular)).foregroundStyle(Palette.muted)
            Text("Apple keeps what you use on this iPhone — Arc Lock never sees app names or your browsing, and sends nothing anywhere.")
                .font(.p(14, .regular)).foregroundStyle(Palette.faint)
        }, button: "Continue", waits: true, action: {
            // granted already (asked before): nothing to ask
            if model.recheckScreenTime() { page = 3; return }
            asking = true
            watchForAccess(seconds: 12)
            Task {
                // never leave the button waiting for long, even if iOS's answer never comes back
                try? await Task.sleep(for: .seconds(12))
                asking = false
            }
            Task {
                let ok = await model.requestScreenTime()
                asking = false
                if ok && page == 2 { page = 3 }
            }
        })
    }

    /// Looks for Screen Time access twice a second for a while: iOS's answer can arrive without the request ever
    /// returning (as on iPad).
    private func watchForAccess(seconds: Int) {
        Task {
            for _ in 0..<(seconds * 2) {
                try? await Task.sleep(for: .milliseconds(500))
                guard page == 2 else { return }
                if model.recheckScreenTime() { asking = false; page = 3; return }
            }
        }
    }

    private var notifications: some View {
        screen(content: {
            Image(systemName: "bell.badge").font(.system(size: 58, weight: .ultraLight)).foregroundStyle(Palette.brass)
            Text("Get a heads-up").font(.p(30, .light, .title)).foregroundStyle(Palette.ink)
            Text("A quiet notice before a block starts, a daily limit runs out, or a break begins.")
                .font(.p(16, .regular)).foregroundStyle(Palette.muted)
        }, button: "Continue", action: {
            // iOS's prompt stays on screen while setup finishes: its answer is handled whenever it comes (on iPad it
            // may never be reported back, which left setup waiting here — App Review 2.1, 1.1.0)
            Task { await model.requestNotifications() }
            model.finishOnboarding()
        })
    }
}
