import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showLockIn = false
    @State private var showGuide = false

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                ScrollView {
                    VStack(spacing: 18) {
                        lockInCard
                        Button { showGuide = true } label: {
                            Card {
                                HStack(spacing: 14) {
                                    Image(systemName: "key.horizontal").font(.system(size: 20, weight: .light)).foregroundStyle(Palette.brass)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Make it harder to break").font(.p(17, .regular)).foregroundStyle(Palette.ink)
                                        Text("Close the last way out, in iOS Settings").font(.p(14, .regular)).foregroundStyle(Palette.muted)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(Palette.faint)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Card {
                            Toggle(isOn: Binding(get: { model.state.headsUp }, set: { model.setHeadsUp($0) })) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Heads-up notifications").font(.p(17, .regular)).foregroundStyle(Palette.ink)
                                    Text("5 minutes before a block starts or a limit of 10 minutes or more runs out").font(.p(14, .regular)).foregroundStyle(Palette.muted)
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
            .sheet(isPresented: $showLockIn) { LockInSheet().environmentObject(model) }
            .sheet(isPresented: $showGuide) { HarderGuide() }
        }
        .presentationBackground(Palette.night)
        #if DEBUG
        .onAppear {
            if Demo.shot == "lockin" { showLockIn = true }
            if Demo.shot == "guide" { showGuide = true }
        }
        #endif
    }

    private var lockInCard: some View {
        Card(glow: model.lockInActive) {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow("Lock-in", color: model.lockInActive ? Palette.brass : Palette.muted)
                if model.lockInActive, let until = model.state.lockInUntil {
                    Text("Locked in through \(Fmt.lastDay(endingAt: until))").font(.p(20, .light, .title3)).foregroundStyle(Palette.ink)
                    Text("Until then no rule can be loosened or deleted and no app can be deleted from this iPhone. You can still add blocks.")
                        .font(.p(14, .regular)).foregroundStyle(Palette.muted)
                    Button("Make it longer") { showLockIn = true }.buttonStyle(GhostButton(tint: Palette.brass))
                } else {
                    Text("Freeze all your rules for a few days — even between blocks. No loosening, no deleting, no deleting apps.")
                        .font(.p(15, .regular)).foregroundStyle(Palette.muted)
                    Button("Lock in…") { showLockIn = true }.buttonStyle(GhostButton(tint: Palette.brass))
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

/// iOS always lets the owner turn off an app's Screen Time access in Settings. This page explains how to put
/// that door behind a Screen Time passcode someone else keeps.
struct HarderGuide: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Make it harder to break").font(.p(30, .extraLight, .largeTitle)).foregroundStyle(Palette.ink)
                            .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.top, 8)
                        Text("Arc Lock already stops you from changing a running block, deleting apps, or setting the clock back. One door stays open by Apple's design: the iPhone's owner can switch off Arc Lock's Screen Time access in Settings. On iOS 26.4 and later, a Screen Time passcode you don't know closes that door too.")
                            .font(.p(15, .regular)).foregroundStyle(Palette.muted)
                        step(1, "Ask a friend to hold a passcode", "Pick someone you trust. They'll type a 4-digit code you don't see.")
                        step(2, "Open Settings › Screen Time", "Tap “Lock Screen Time Settings” (or “Use Screen Time Passcode”) and hand your friend the phone.")
                        step(3, "Recovery goes to your friend", "When iOS asks for an Apple Account to recover the passcode, your friend enters their own. Don't skip this: a passcode nobody can recover can mean erasing the iPhone.")
                        step(4, "Keep iOS up to date", "Some iOS versions still let Face ID switch access off under Settings › Apps › Arc Lock. Updates close gaps like this.")
                        step(5, "Optional: stop app deletion for good", "In Screen Time › Content & Privacy Restrictions, set Deleting Apps to Don't Allow.")
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
