import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showGuide = false

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                ScrollView {
                    VStack(spacing: 18) {
                        strictCard
                        protectionCard
                        Card {
                            Toggle(isOn: Binding(get: { model.state.headsUp }, set: { model.setHeadsUp($0) })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Heads-up notifications").font(.p(17, .regular)).foregroundStyle(Palette.ink)
                                    Text("Before a block starts, a daily limit runs out, or a time-out's break begins").font(.p(14, .regular)).foregroundStyle(Palette.muted)
                                }
                            }
                            .tint(Palette.brass)
                        }
                        aboutCard
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle(Text("Settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showGuide) { HarderGuide() }
        }
        .presentationBackground(Palette.night)
        #if DEBUG
        .onAppear {
            if Demo.shot == "guide" { showGuide = true }
        }
        #endif
    }

    private var strictCard: some View {
        Card(glow: model.state.strictLock) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { model.state.strictLock && model.state.strictLockOffAt == nil },
                                     set: { on in
                                         switch model.setStrictLock(on) {
                                         case .refused(let why): model.problem = why
                                         case .scheduled(let at): model.toast = String(localized: "Strict lock turns off at \(Fmt.moment(at, now: model.now)).")
                                         case .saved: break
                                         }
                                     })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Strict lock").font(.p(17, .regular)).foregroundStyle(Palette.ink)
                        Text(model.state.strictLock
                             ? "Blocks set to Strict lock can't be stopped, loosened or deleted while they run. Turning it off takes effect at midnight, after any strict block running then has ended."
                             : "Off: every block can be stopped or changed any time. Lock-in needs it on.")
                            .font(.p(14, .regular)).foregroundStyle(Palette.muted)
                    }
                }
                .tint(Palette.brass)
                if model.state.strictLock, let off = model.state.strictLockOffAt {
                    let at = model.lockInActive ? max(off, model.state.lockInUntil ?? off) : off
                    HStack {
                        Text(at <= model.now ? String(localized: "Turns off when the strict blocks running now end")
                                             : String(localized: "Turns off at \(Fmt.moment(at, now: model.now))"))
                            .font(.p(13, .regular, .footnote)).foregroundStyle(Palette.brass)
                        Spacer()
                        Button("Keep it on") { _ = model.setStrictLock(true) }
                            .font(.p(14, .medium)).foregroundStyle(Palette.brass)
                    }
                }
            }
        }
    }

    private var protectionCard: some View {
        Card(glow: model.state.deletionProtection) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: Binding(get: { model.state.deletionProtection && model.state.deletionProtectionOffAt == nil },
                                     set: { on in
                                         switch model.setDeletionProtection(on) {
                                         case .refused(let why): model.problem = why
                                         case .scheduled(let at): model.toast = String(localized: "Deletion protection turns off at \(Fmt.moment(at, now: model.now)).")
                                         case .saved: break
                                         }
                                     })) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Deletion protection").font(.p(17, .regular)).foregroundStyle(Palette.ink)
                        Text(model.state.strictLock
                             ? "No app can be deleted from this iPhone, Arc Lock included. Turning it off takes effect at midnight."
                             : "No app can be deleted from this iPhone, Arc Lock included.")
                            .font(.p(14, .regular)).foregroundStyle(Palette.muted)
                    }
                }
                .tint(Palette.brass)
                if model.state.deletionProtection, let off = model.state.deletionProtectionOffAt {
                    HStack {
                        Text("Turns off at \(Fmt.moment(model.lockInActive ? max(off, model.state.lockInUntil ?? off) : off, now: model.now))")
                            .font(.p(13, .regular, .footnote)).foregroundStyle(Palette.brass)
                        Spacer()
                        Button("Keep it on") { _ = model.setDeletionProtection(true) }
                            .font(.p(14, .medium)).foregroundStyle(Palette.brass)
                    }
                }
            }
        }
    }

    private var aboutCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow("About", color: Palette.muted)
                link("How Arc Lock works", "https://github.com/WeldingArc/arc-lock#how-it-works")
                link("Source code (MIT)", "https://github.com/WeldingArc/arc-lock")
                link("Privacy: nothing leaves this iPhone", "https://github.com/WeldingArc/arc-lock/blob/main/PRIVACY.md")
                link("Report a problem", "https://github.com/WeldingArc/arc-lock/issues")
                Button { showGuide = true } label: {
                    HStack {
                        Text("Extra protection with a friend").font(.p(16, .regular)).foregroundStyle(Palette.ink)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(Palette.faint)
                    }
                }
                .buttonStyle(.plain)
                Text("Arc Lock \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") · Free, no account, no ads. Pretendard font under the SIL Open Font License.")
                    .font(.p(12, .regular, .caption)).foregroundStyle(Palette.faint)
            }
        }
    }

    private func link(_ title: LocalizedStringKey, _ url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Text(title).font(.p(16, .regular)).foregroundStyle(Palette.ink)
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 13)).foregroundStyle(Palette.faint)
            }
        }
    }
}

struct LockInSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var days = 7
    @State private var typed = ""
    private let choices = [1, 3, 7, 14, 30]
    private var end: Date { Calendar.current.date(byAdding: .day, value: days + 1, to: Calendar.current.startOfDay(for: model.now))! }
    private var word: String { String(localized: "LOCK") }

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                ScrollView {
                    VStack(spacing: 20) {
                        ArcMark(size: 64).padding(.top, 12)
                        Text("Lock in").font(.p(32, .extraLight, .largeTitle)).foregroundStyle(Palette.ink)
                        Text("For the days you choose, every rule stays exactly as it is or gets stricter, and no app can be deleted. There is no early exit.")
                            .font(.p(15, .regular)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                        HStack(spacing: 8) {
                            ForEach(choices, id: \.self) { d in
                                Button { days = d } label: {
                                    Text("\(d)d")
                                        .font(.p(15, days == d ? .semibold : .regular))
                                        .foregroundStyle(days == d ? Palette.night : Palette.muted)
                                        .frame(maxWidth: .infinity, minHeight: 42)
                                        .background(Capsule().fill(days == d ? Palette.brass : Color.white.opacity(0.04)))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text("\(d) days"))
                            }
                        }
                        Text("Through \(Fmt.lastDay(endingAt: end))").font(.p(20, .light)).foregroundStyle(Palette.ink)
                        if !model.state.strictLock || model.state.strictLockOffAt != nil {
                            Text("Lock-in needs Strict lock. Turn it on in Settings first.")
                                .font(.p(14, .regular)).foregroundStyle(Palette.rose).multilineTextAlignment(.center)
                        }
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Type \(word) to confirm").font(.p(14, .regular)).foregroundStyle(Palette.muted)
                                TextField(text: $typed, prompt: Text(word).foregroundStyle(Palette.faint)) { Text("Confirmation") }
                                    .font(.p(20, .light))
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                            }
                        }
                        Button("Lock in through \(Fmt.lastDay(endingAt: end))") {
                            switch model.startLockIn(days: days) {
                            case .refused(let why): model.problem = why
                            default: dismiss()
                            }
                        }
                        .buttonStyle(BrassButton())
                        .disabled(typed.trimmingCharacters(in: .whitespaces).uppercased() != word.uppercased())
                        .opacity(typed.trimmingCharacters(in: .whitespaces).uppercased() == word.uppercased() ? 1 : 0.5)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.foregroundStyle(Palette.muted) } }
        }
        .presentationBackground(Palette.night)
    }
}

/// Optional: lock iOS's Screen Time settings with a passcode a friend keeps.
struct HarderGuide: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Extra protection").font(.p(30, .extraLight, .largeTitle)).foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 8)
                        Text("Put iOS's own Screen Time settings behind a passcode that only a friend knows.")
                            .font(.p(15, .regular)).foregroundStyle(Palette.muted)
                        step(1, "Ask a friend to hold a passcode", "Pick someone you trust. They'll type a 4-digit code you don't see.")
                        step(2, "Open Settings › Screen Time", "Tap “Lock Screen Time Settings” (or “Use Screen Time Passcode”) and hand your friend the phone.")
                        step(3, "Recovery goes to your friend", "When iOS asks for an Apple Account to recover the passcode, your friend enters their own. Don't skip this: a passcode nobody can recover can mean erasing the iPhone.")
                        Text("In a real emergency your friend can always give you the code. That's the point: a pause long enough for the urge to pass.")
                            .font(.p(14, .regular)).foregroundStyle(Palette.faint)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, 32)
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationBackground(Palette.night)
    }

    private func step(_ n: Int, _ title: LocalizedStringKey, _ body: LocalizedStringKey) -> some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Text("\(n)").font(.p(22, .extraLight)).foregroundStyle(Palette.brass).frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.p(17, .regular)).foregroundStyle(Palette.ink)
                    Text(body).font(.p(14, .regular)).foregroundStyle(Palette.muted)
                }
            }
        }
    }
}
