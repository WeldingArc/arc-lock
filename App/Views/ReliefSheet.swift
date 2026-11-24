import SwiftUI

/// Emergency relief, step 1: what it does and RELIEF typed; step 2 (ReliefConfirm) says what it does and asks for
/// "Lift my blocks" held for 3 seconds. The same deliberate steps as Lock in: lifting every block takes a decision,
/// not a tap.
struct ReliefSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @State private var confirming = false
    @State private var refusal: String?
    private var word: String { String(localized: "RELIEF") }
    private var typedRight: Bool { typed.trimmingCharacters(in: .whitespaces).uppercased() == word.uppercased() }

    var body: some View {
        NavigationStack {
            ZStack {
                Backdrop()
                ScrollView {
                    VStack(spacing: 20) {
                        ArcMark(size: 64).padding(.top, 12)
                        Text("Emergency relief").font(.p(32, .extraLight, .largeTitle)).foregroundStyle(Palette.ink)
                        Text("Lift every block for \(ReliefRules.minutes) minutes, strict blocks and lock-ins included. You get one every \(ReliefRules.refillDays) days.")
                            .font(.p(15, .regular)).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                        Text("If you use it now, the next one is available on \(Fmt.dayAndTime(model.reliefRefill)).")
                            .font(.p(15, .regular)).foregroundStyle(Palette.brass).multilineTextAlignment(.center)
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Type \(word) to confirm").font(.p(14, .regular)).foregroundStyle(Palette.muted)
                                TextField(text: $typed, prompt: Text(word).foregroundStyle(Palette.faint)) { Text("Confirmation") }
                                    .font(.p(20, .light))
                                    .textInputAutocapitalization(.characters)
                                    .autocorrectionDisabled()
                            }
                        }
                        Button("Continue") {
                            // the warning and the hold come next; say now if it can't start at all
                            if let why = model.reliefRefusal() { refusal = why } else { confirming = true }
                        }
                        .buttonStyle(BrassButton())
                        .disabled(!typedRight)
                        .opacity(typedRight ? 1 : 0.5)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.foregroundStyle(Palette.muted) } }
            .navigationDestination(isPresented: $confirming) {
                ReliefConfirm(done: { dismiss() }).environmentObject(model)
            }
            .problemAlert($refusal)
        }
        .presentationBackground(Palette.night)
    }
}

/// The last step of an emergency relief: what it does, then "Lift my blocks" held for 3 seconds. While it's held the
/// iPhone buzzes faster and harder; one strong buzz says the blocks are lifted.
struct ReliefConfirm: View {
    @EnvironmentObject private var model: AppModel
    /// Closes the relief sheet once the blocks are lifted.
    let done: () -> Void
    @State private var lifted = false
    @State private var refusal: String?
    /// Kept here, not in the button: the strong buzz plays on after the button has gone.
    @StateObject private var haptics = HoldHaptics()

    var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                VStack(spacing: 18) {
                    ArcMark(size: 64, locked: !lifted).padding(.top, 8)
                    Text(lifted ? "Blocks lifted" : "Lift your blocks?")
                        .font(.p(32, .extraLight, .largeTitle))
                        .foregroundStyle(Palette.ink)
                    if lifted, let back = model.reliefUntil {
                        Text("Blocks return at \(Fmt.time(back))")
                            .font(.p(16, .regular))
                            .foregroundStyle(Palette.brass)
                    } else if !lifted {
                        Text("Your blocks lift as soon as you confirm and come back after \(ReliefRules.minutes) minutes.")
                            .font(.p(16, .regular))
                            .foregroundStyle(Palette.muted)
                        // what a relief does (Core ReliefRules; Shielding.apply lifts the shields, nothing else)
                        Card {
                            VStack(alignment: .leading, spacing: 16) {
                                point("lock.open", "Every app and website your blocks hold opens, strict blocks and Block now included.")
                                point("clock.arrow.circlepath", "Your blocks come back on their own after \(ReliefRules.minutes) minutes, even if Arc Lock stays closed.")
                                point("trash.slash", "Deletion protection and the clock lock stay as they are.")
                                point("lock.shield", "Your rules, limits and lock-in don't change. Limits and time-outs keep counting, and a limit used up now locks when relief ends.")
                                point("calendar", "You get one every \(ReliefRules.refillDays) days. The next one is available on \(Fmt.dayAndTime(model.reliefRefill)).")
                            }
                        }
                        Text("It buzzes as it fills. One strong buzz means your blocks are lifted.")
                            .font(.p(13, .regular, .footnote))
                            .foregroundStyle(Palette.faint)
                    }
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !lifted {
                HoldToConfirm(title: "Lift my blocks", seconds: 3, doneIcon: "lock.open.fill", haptics: haptics, action: confirm)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    // solid, with a short fade above it: the text scrolled under it doesn't show through
                    .background {
                        VStack(spacing: 0) {
                            LinearGradient(colors: [Palette.night.opacity(0), Palette.night], startPoint: .top, endPoint: .bottom)
                                .frame(height: 18)
                            Palette.night
                        }
                        .padding(.top, -18)
                        .ignoresSafeArea(edges: .bottom)
                    }
            }
        }
        .navigationBarBackButtonHidden(lifted)
        .animation(.easeInOut(duration: 0.3), value: lifted)
        .problemAlert($refusal)
        .onAppear { haptics.prepare() }
    }

    private func point(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(Palette.brass)
                .frame(width: 24)
            Text(text)
                .font(.p(15, .regular))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Lifts the blocks once the hold is complete. Returns whether it worked (the strong buzz follows only then).
    private func confirm() -> Bool {
        switch model.startRelief() {
        case .refused(let why):
            refusal = why
            return false
        default:
            lifted = true
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                done()
            }
            return true
        }
    }
}
