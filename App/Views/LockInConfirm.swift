import CoreHaptics
import SwiftUI

/// The last step of a lock-in: what it does, then "I am sure" held for 3 seconds. While it's held the iPhone buzzes
/// faster and harder; one strong buzz says the lock-in has started.
struct LockInConfirm: View {
    @EnvironmentObject private var model: AppModel
    let days: Int
    /// The end shown on the first page when Lock in was tapped (kept, even if midnight passes on this page).
    let end: Date
    /// Closes the Lock in sheet once the lock-in has started.
    let done: () -> Void
    @State private var locked = false
    @State private var refusal: String?
    /// Kept here, not in the button: the strong buzz plays on after the button has gone.
    @StateObject private var haptics = HoldHaptics()

    private var through: String { Fmt.lastDay(endingAt: end) }

    var body: some View {
        ZStack {
            Backdrop()
            ScrollView {
                VStack(spacing: 18) {
                    ArcMark(size: 64, locked: locked).padding(.top, 8)
                    Text(locked ? "Locked in" : "Are you sure?")
                        .font(.p(32, .extraLight, .largeTitle))
                        .foregroundStyle(Palette.ink)
                    Text(locked ? "Through \(through)" : "Lock-in starts as soon as you confirm and lasts through \(through).")
                        .font(.p(16, .regular))
                        .foregroundStyle(locked ? Palette.brass : Palette.muted)
                    if !locked {
                        // what a lock-in does (Core Policy: every block is locked; only new blocks can be added)
                        Card {
                            VStack(alignment: .leading, spacing: 16) {
                                point("trash.slash", "Arc Lock can't be deleted, and neither can any other app on this iPhone.")
                                point("lock.shield", "This setting can't be changed: the lock-in can only be made longer, never shorter or turned off, and Strict lock stays on until it ends.")
                                point("lock", "Every block stays exactly as it is, and blocks you stopped start again. None can be stopped, changed or deleted.")
                                point("calendar", "There's no early exit. It ends on its own after \(through).")
                                point("plus.circle", "You can still add new blocks.")
                            }
                        }
                        Text("It buzzes as it fills. One strong buzz means you're locked in.")
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
            if !locked {
                HoldToConfirm(title: "I am sure", seconds: 3, haptics: haptics, action: confirm)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    // solid, with a short fade above it: the warnings scrolled under it don't show through
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
        .navigationBarBackButtonHidden(locked)
        .animation(.easeInOut(duration: 0.3), value: locked)
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

    /// Starts the lock-in once the hold is complete. Returns whether it started (the strong buzz follows only then).
    private func confirm() -> Bool {
        switch model.startLockIn(days: days, shownEnd: end) {
        case .refused(let why):
            refusal = why
            return false
        default:
            locked = true
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                done()
            }
            return true
        }
    }
}

/// A button that acts only after it's held for `seconds`: it fills while held and empties if let go early. The iPhone
/// buzzes faster and harder as it fills, then once, strongly, when the action has worked. It grows with the text size.
struct HoldToConfirm: View {
    let title: LocalizedStringKey
    var seconds: Double = 3
    let haptics: HoldHaptics
    /// Runs when the hold is complete; returns whether it worked.
    let action: () -> Bool
    @State private var progress: CGFloat = 0
    @State private var holding = false
    @State private var finished = false
    @State private var tooSoon = false
    @State private var pressedAt: Date?
    /// Waits briefly after a release at the very end of the hold (iOS may report it just before the success).
    @State private var releaseCheck: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 12) {
            Text(prompt)
                .font(.p(15, holding ? .medium : .regular))
                .foregroundStyle(tooSoon ? Palette.rose : Palette.ink)
                .multilineTextAlignment(.center)
            label.foregroundStyle(Palette.brass)
                .background(alignment: .leading) {
                    GeometryReader { g in Rectangle().fill(Palette.brass).frame(width: g.size.width * progress) }
                }
                .background(Palette.brass.opacity(0.16))
                // the words in the fill's colors where it has reached
                .overlay {
                    label.foregroundStyle(Palette.night)
                        .mask(alignment: .leading) {
                            GeometryReader { g in Rectangle().frame(width: g.size.width * progress) }
                        }
                }
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(Palette.brass.opacity(0.7), lineWidth: 1.5))
                .contentShape(Capsule())
                .scaleEffect(holding ? 0.97 : 1)
                .animation(.spring(duration: 0.25), value: holding)
                .onLongPressGesture(minimumDuration: seconds, maximumDistance: 60, perform: complete, onPressingChanged: pressing)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(title))
                .accessibilityHint(Text("Double-tap and hold for \(Int(seconds)) seconds."))
                .accessibilityAddTraits(.isButton)
        }
        .onDisappear { haptics.cancel() }
    }

    private var label: some View {
        HStack(spacing: 8) {
            Image(systemName: finished ? "lock.fill" : "hand.point.up.left.fill")
            Text(title)
        }
        .font(.p(17, .semibold, .headline))
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: 58)
    }

    private var prompt: LocalizedStringKey {
        if holding { return "Keep holding…" }
        if tooSoon { return "Let go too soon. Hold it for the full \(Int(seconds)) seconds." }
        return "Press and hold for \(Int(seconds)) seconds."
    }

    private func pressing(_ down: Bool) {
        guard !finished else { return }
        if down {
            releaseCheck?.cancel()
            releaseCheck = nil
            pressedAt = Date()
            holding = true
            tooSoon = false
            haptics.begin(seconds: seconds)
            withAnimation(.linear(duration: seconds)) { progress = 1 }
        } else if let at = pressedAt, Date().timeIntervalSince(at) >= seconds - 0.1 {
            // held to the very end: iOS may report the release just before the success, so wait a moment for it
            releaseCheck = Task {
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                if !finished { letGo() }
            }
        } else {
            letGo()
        }
    }

    /// Let go before the end: it empties, and says to hold the whole time.
    private func letGo() {
        holding = false
        tooSoon = true
        haptics.cancel()
        withAnimation(.easeOut(duration: 0.25)) { progress = 0 }
    }

    private func complete() {
        guard !finished else { return }
        releaseCheck?.cancel()
        releaseCheck = nil
        finished = true
        holding = false
        tooSoon = false
        progress = 1
        if action() {
            haptics.finish()
        } else {
            haptics.cancel()
            finished = false
            withAnimation(.easeOut(duration: 0.25)) { progress = 0 }
        }
    }
}

/// Core Haptics for a hold: short buzzes that come closer together and get stronger over the hold, then one strong
/// buzz to confirm. Silent where there's no Taptic Engine (iPad, simulator).
@MainActor final class HoldHaptics: ObservableObject {
    private var engine: CHHapticEngine?
    private var player: CHHapticAdvancedPatternPlayer?
    private var confirmation: CHHapticPatternPlayer?

    func prepare() {
        guard engine == nil, CHHapticEngine.capabilitiesForHardware().supportsHaptics,
              let e = try? CHHapticEngine() else { return }
        e.playsHapticsOnly = true
        e.isAutoShutdownEnabled = true
        e.resetHandler = { [weak e] in try? e?.start() }
        engine = e
    }

    func begin(seconds: Double) {
        guard let engine, let pattern = try? Self.rising(seconds) else { return }
        try? engine.start()
        player = try? engine.makeAdvancedPlayer(with: pattern)
        try? player?.start(atTime: CHHapticTimeImmediate)
    }

    func cancel() {
        try? player?.stop(atTime: CHHapticTimeImmediate)
        player = nil
    }

    func finish() {
        cancel()
        guard let engine, let pattern = try? Self.strong() else { return }
        try? engine.start()
        confirmation = try? engine.makePlayer(with: pattern)
        try? confirmation?.start(atTime: CHHapticTimeImmediate)
    }

    /// Short buzzes, closer together and stronger as the hold goes on (about 16 over 3 seconds).
    private static func rising(_ seconds: Double) throws -> CHHapticPattern {
        var events: [CHHapticEvent] = []
        var t = 0.0
        var gap = 0.42
        while t < seconds - 0.06 {
            let x = Float(t / seconds)
            events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.25 + 0.6 * x),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.2 + 0.5 * x),
            ], relativeTime: t, duration: 0.08 + 0.06 * Double(x)))
            t += gap
            gap = max(0.12, gap * 0.85)
        }
        return try CHHapticPattern(events: events, parameters: [])
    }

    /// The confirmation: one sharp hit and a long, strong buzz.
    private static func strong() throws -> CHHapticPattern {
        try CHHapticPattern(events: [
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 1),
            ], relativeTime: 0),
            CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6),
            ], relativeTime: 0.03, duration: 0.55),
        ], parameters: [])
    }
}
