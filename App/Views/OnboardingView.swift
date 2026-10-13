import SwiftUI

/// First run: what Arc Lock does, then Screen Time access (required) and notifications (optional).
struct OnboardingView: View {
    @EnvironmentObject private var model: AppModel
    @State private var page = 0
    @State private var asking = false

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                welcome.tag(0)
                how.tag(1)
                access.tag(2)
                notifications.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut, value: page)
            dots.padding(.bottom, 18)
        }
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
                                       secondary: LocalizedStringKey? = nil, action: @escaping () -> Void,
                                       secondaryAction: (() -> Void)? = nil) -> some View {
        VStack(spacing: 22) {
            Spacer(minLength: 20)
            content()
            Spacer(minLength: 20)
            Button(button, action: action).buttonStyle(BrassButton()).disabled(asking)
            if let secondary, let secondaryAction {
                Button(secondary, action: secondaryAction).font(.p(16, .regular)).foregroundStyle(Palette.muted).frame(minHeight: 44)
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
                feature("hourglass", "Daily limits", "After the time you allow, they lock until midnight.")
                feature("lock.fill", "No early exit", "A running block can't be stopped, and Arc Lock can't be deleted.")
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
            Text("Allow Screen Time access").font(.p(30, .light, .title)).foregroundStyle(Palette.ink)
            Text("Arc Lock blocks apps through Apple's Screen Time. iOS will ask for your Face ID or passcode.")
                .font(.p(16, .regular)).foregroundStyle(Palette.muted)
            Text("Apple keeps what you use on this iPhone — Arc Lock never sees app names or your browsing, and sends nothing anywhere.")
                .font(.p(14, .regular)).foregroundStyle(Palette.faint)
        }, button: "Allow", action: {
            asking = true
            Task {
                // iOS answers within seconds on a real iPhone; never leave the button dead if it doesn't
                try? await Task.sleep(for: .seconds(45))
                asking = false
            }
            Task {
                let ok = await model.requestScreenTime()
                asking = false
                if ok { page = 3 }
            }
        })
    }

    private var notifications: some View {
        screen(content: {
            Image(systemName: "bell.badge").font(.system(size: 58, weight: .ultraLight)).foregroundStyle(Palette.brass)
            Text("Get a heads-up").font(.p(30, .light, .title)).foregroundStyle(Palette.ink)
            Text("A quiet notice 5 minutes before a block starts or a daily limit runs out.")
                .font(.p(16, .regular)).foregroundStyle(Palette.muted)
        }, button: "Allow notifications", secondary: "Not now", action: {
            Task {
                await model.requestNotifications()
                model.finishOnboarding()
            }
        }, secondaryAction: {
            model.setHeadsUp(false)
            model.finishOnboarding()
        })
    }
}
