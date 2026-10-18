// Arc family look: a deep background, one accent, Pretendard in thin weights, centered and roomy. The colors come from
// the chosen theme (Shared/Themes.swift); `brass` is the theme's accent (it's brass in the original Navy theme).
import FamilyControls
import ManagedSettings
import SwiftUI

enum Palette {
    private static var t: ThemeColors { ArcTheme.current.colors }
    static var night: Color { Color(hex: t.night) }
    static var deep: Color { Color(hex: t.deep) }
    static var card: Color { Color(hex: t.card) }
    static var cardHi: Color { Color(hex: t.cardHi) }
    static var line: Color { wash(0.08) }
    static var ink: Color { Color(hex: t.ink) }
    static var muted: Color { Color(hex: t.muted) }
    static var faint: Color { Color(hex: t.faint) }
    static var brass: Color { Color(hex: t.accent) }
    static var accentLight: Color { Color(hex: t.accentLight) }
    static var accentDark: Color { Color(hex: t.accentDark) }
    static var brassSoft: Color { brass.opacity(0.14) }
    static var sage: Color { Color(hex: t.sage) }
    static var rose: Color { Color(hex: t.rose) }
    /// A faint fill or hairline that reads on the theme's background: white on dark themes, black on Paper.
    static func wash(_ opacity: Double) -> Color {
        ArcTheme.current.isLight ? Color.black.opacity(opacity * 0.8) : Color.white.opacity(opacity)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

enum PWeight: String {
    case extraLight = "Pretendard-ExtraLight", light = "Pretendard-Light", regular = "Pretendard-Regular"
    case medium = "Pretendard-Medium", semibold = "Pretendard-SemiBold"
}

extension Font {
    /// Pretendard that still follows the reader's text size setting.
    static func p(_ size: CGFloat, _ weight: PWeight = .regular, _ style: Font.TextStyle = .body) -> Font {
        .custom(weight.rawValue, size: size, relativeTo: style)
    }
}

struct Backdrop: View {
    var body: some View {
        ZStack {
            Palette.night
            RadialGradient(colors: [Palette.brass.opacity(0.12), .clear], center: .top, startRadius: 0, endRadius: 460)
        }
        .ignoresSafeArea()
    }
}

struct Card<Content: View>: View {
    var glow = false
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(glow ? Palette.cardHi : Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(glow ? Palette.brass.opacity(0.45) : Palette.line, lineWidth: 1))
    }
}

struct Eyebrow: View {
    let text: LocalizedStringKey
    var color = Palette.brass
    init(_ text: LocalizedStringKey, color: Color = Palette.brass) { self.text = text; self.color = color }
    var body: some View {
        Text(text).font(.p(12, .medium, .caption)).tracking(2.2).textCase(.uppercase).foregroundStyle(color)
    }
}

struct BrassButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.p(17, .medium, .headline))
            .foregroundStyle(Palette.night)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Capsule().fill(Palette.brass.opacity(configuration.isPressed ? 0.8 : 1)))
            .contentShape(Capsule())
    }
}

struct GhostButton: ButtonStyle {
    var tint = Palette.ink
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.p(16, .regular, .headline))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Capsule().fill(Palette.wash(configuration.isPressed ? 0.08 : 0.03)))
            .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// The Arc Lock mark: an iPhone with a lock on its screen, the same drawing as the app icon
/// (tools/make_phone_icon.swift). The lock closes while something is blocked and opens when nothing is.
struct ArcMark: View {
    var size: CGFloat = 72
    var locked = true

    var body: some View {
        let w = size * 0.5, h = size
        let accent = LinearGradient(colors: [Palette.accentLight, Palette.brass, Palette.accentDark],
                                    startPoint: .topLeading, endPoint: .bottomTrailing)
        let t = w * 0.075
        ZStack {
            RoundedRectangle(cornerRadius: w * 0.24, style: .continuous)
                .fill(Palette.cardHi.opacity(0.85))
                .padding(t / 2)
            RoundedRectangle(cornerRadius: w * 0.24, style: .continuous)
                .strokeBorder(accent, lineWidth: t)
            Capsule().fill(Palette.brass.opacity(0.85))
                .frame(width: w * 0.30, height: w * 0.085)
                .position(x: w / 2, y: t + w * 0.07 + w * 0.0425)
            LockShackle(openness: locked ? 0 : 1)
                .stroke(accent, style: StrokeStyle(lineWidth: t * 0.95, lineCap: .round))
            LockBody()
                .fill(accent)
            LockKeyhole()
                .fill(Palette.night)
        }
        .frame(width: w, height: h)
        .frame(width: size, height: size)
        .animation(.spring(response: 0.5, dampingFraction: 0.62), value: locked)
        .accessibilityHidden(true)
    }
}

/// Geometry shared by the lock's parts, in the phone's frame (width w, height h).
private struct LockGeometry {
    let w: CGFloat, h: CGFloat
    init(_ r: CGRect) { w = r.width; h = r.height }
    var bodyW: CGFloat { w * 0.52 }
    var bodyH: CGFloat { bodyW * 0.72 }
    var bodyY: CGFloat { h / 2 - bodyH * 0.12 }
    var body: CGRect { CGRect(x: w / 2 - bodyW / 2, y: bodyY, width: bodyW, height: bodyH) }
    var shackleR: CGFloat { bodyW * 0.29 }
    var shackleT: CGFloat { w * 0.075 * 0.95 }
}

/// The shackle; `openness` 0 = shut, 1 = lifted with the right leg out of the body (animatable).
struct LockShackle: Shape {
    var openness: CGFloat
    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }
    func path(in r: CGRect) -> Path {
        let g = LockGeometry(r)
        let lift = g.bodyW * 0.20 * openness
        let center = CGPoint(x: r.midX, y: r.minY + g.bodyY - g.bodyW * 0.20 - lift)
        let foot = r.minY + g.bodyY + g.shackleT * 0.6
        var p = Path()
        p.move(to: CGPoint(x: r.midX - g.shackleR, y: foot - lift))
        p.addLine(to: CGPoint(x: r.midX - g.shackleR, y: center.y))
        p.addArc(center: center, radius: g.shackleR, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        // the right leg leaves the body as it opens
        p.addLine(to: CGPoint(x: r.midX + g.shackleR, y: foot + (center.y + g.bodyW * 0.05 - foot) * openness))
        return p
    }
}

struct LockBody: Shape {
    func path(in r: CGRect) -> Path {
        let g = LockGeometry(r)
        return Path(roundedRect: g.body.offsetBy(dx: r.minX, dy: r.minY), cornerRadius: g.bodyW * 0.16, style: .continuous)
    }
}

struct LockKeyhole: Shape {
    func path(in r: CGRect) -> Path {
        let g = LockGeometry(r)
        let c = CGPoint(x: r.minX + g.body.midX, y: r.minY + g.body.midY - g.bodyH * 0.08)
        var p = Path()
        p.addEllipse(in: CGRect(x: c.x - g.bodyW * 0.075, y: c.y - g.bodyW * 0.075, width: g.bodyW * 0.15, height: g.bodyW * 0.15))
        p.addRoundedRect(in: CGRect(x: c.x - g.bodyW * 0.032, y: c.y, width: g.bodyW * 0.064, height: g.bodyH * 0.32),
                         cornerSize: CGSize(width: g.bodyW * 0.032, height: g.bodyW * 0.032))
        return p
    }
}

/// A theme's colors as a split circle (background and accent), ringed when chosen.
struct ThemeSwatch: View {
    let theme: ArcTheme
    var selected = false
    var body: some View {
        let c = theme.colors
        Circle()
            .fill(LinearGradient(stops: [.init(color: Color(hex: c.night), location: 0.5), .init(color: Color(hex: c.accent), location: 0.5)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(Circle().strokeBorder(Palette.line, lineWidth: 1))
            .frame(width: 38, height: 38)
            .padding(4)
            .overlay(Circle().strokeBorder(selected ? Palette.brass : .clear, lineWidth: 2))
    }
}

/// Up to `max` app/category/website icons from a selection, then "+N".
struct TokenIcons: View {
    let selection: FamilyActivitySelection
    var max = 6
    var demoName: String? = nil
    var body: some View {
        #if DEBUG
        if Demo.isOn, selection.isEmpty, let name = demoName, !Demo.icons(for: name).isEmpty {
            HStack(spacing: 6) {
                ForEach(Array(Demo.icons(for: name).enumerated()), id: \.offset) { _, icon in
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hue: icon.hue, saturation: 0.45, brightness: 0.62),
                                                      Color(hue: icon.hue, saturation: 0.55, brightness: 0.42)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(Image(systemName: icon.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.9)))
                        .frame(width: 26, height: 26)
                }
            }
        } else {
            tokens
        }
        #else
        tokens
        #endif
    }

    @ViewBuilder private var tokens: some View {
        let apps = Array(selection.applicationTokens).prefix(max)
        let cats = Array(selection.categoryTokens).prefix(Swift.max(0, max - apps.count))
        let webs = Array(selection.webDomainTokens).prefix(Swift.max(0, max - apps.count - cats.count))
        let extra = selection.itemCount - apps.count - cats.count - webs.count
        HStack(spacing: 6) {
            ForEach(Array(apps), id: \.self) { Label($0).labelStyle(.iconOnly).frame(width: 26, height: 26) }
            ForEach(Array(cats), id: \.self) { Label($0).labelStyle(.iconOnly).frame(width: 26, height: 26) }
            ForEach(Array(webs), id: \.self) { Label($0).labelStyle(.iconOnly).frame(width: 26, height: 26) }
            if extra > 0 { Text("+\(extra)").font(.p(13, .regular)).foregroundStyle(Palette.muted) }
        }
    }
}

/// Seven round day toggles in the reader's week order.
struct DayChips: View {
    @Binding var days: Set<Int>
    var disabled = false
    var body: some View {
        let cal = Calendar.current
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let order = (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 + 1 }
        HStack(spacing: 8) {
            ForEach(order, id: \.self) { day in
                let on = days.contains(day)
                Button {
                    if on { days.remove(day) } else { days.insert(day) }
                } label: {
                    Text(symbols[day - 1])
                        .font(.p(14, on ? .semibold : .regular, .callout))
                        .foregroundStyle(on ? Palette.night : Palette.muted)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(on ? Palette.brass : Palette.wash(0.04)))
                        .overlay(Circle().strokeBorder(on ? .clear : Palette.line, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .accessibilityLabel(cal.standaloneWeekdaySymbols[day - 1])
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// Small rounded label for a rule's state.
struct Pill: View {
    let text: String
    var tint = Palette.muted
    var icon: String?
    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
            Text(text).font(.p(12, .medium, .caption))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

extension Set where Element == Int {
    /// "Every day", "Weekdays", "Weekends" or "Mon, Wed, Fri".
    var dayText: String {
        if count == 7 { return String(localized: "Every day") }
        if self == [2, 3, 4, 5, 6] { return String(localized: "Weekdays") }
        if self == [1, 7] { return String(localized: "Weekends") }
        let cal = Calendar.current
        let order = (0..<7).map { (cal.firstWeekday - 1 + $0) % 7 + 1 }
        return order.filter(contains).map { cal.shortStandaloneWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
    }
}

extension TimeOfDay {
    var date: Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }
    init(date: Date) {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        self.init(c.hour ?? 0, c.minute ?? 0)
    }
    var text: String { Fmt.time(date) }
}

func durationText(_ seconds: TimeInterval) -> String {
    let f = DateComponentsFormatter()
    f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
    f.unitsStyle = .short
    f.zeroFormattingBehavior = .dropAll
    return f.string(from: max(60, seconds.rounded(.up))) ?? ""
}

func minutesText(_ minutes: Int) -> String { durationText(TimeInterval(minutes * 60)) }
