// Arc family look: deep navy, brass accent, Pretendard in thin weights, centered and roomy.
import FamilyControls
import ManagedSettings
import SwiftUI

enum Palette {
    static let night = Color(hex: 0x0E1424)
    static let deep = Color(hex: 0x0A0F1C)
    static let card = Color(hex: 0x151D31)
    static let cardHi = Color(hex: 0x1B2540)
    static let line = Color.white.opacity(0.08)
    static let ink = Color(hex: 0xE9E6DF)
    static let muted = Color(hex: 0x9AA1B1)
    static let faint = Color(hex: 0x6B7385)
    static let brass = Color(hex: 0xC8A96A)
    static let brassSoft = Color(hex: 0xC8A96A).opacity(0.14)
    static let sage = Color(hex: 0x8FB3A0)
    static let rose = Color(hex: 0xD49A8C)
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
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.08 : 0.03)))
            .overlay(Capsule().strokeBorder(Palette.line, lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// The Arc Lock mark: a brass arc as the shackle over a quiet lock body.
struct ArcMark: View {
    var size: CGFloat = 72
    var locked = true
    var body: some View {
        ZStack {
            ArcShackle(open: !locked)
                .stroke(LinearGradient(colors: [Palette.brass, Palette.brass.opacity(0.65)], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: size * 0.085, lineCap: .round))
                .frame(width: size * 0.56, height: size * 0.5)
                .offset(y: -size * 0.2)
            RoundedRectangle(cornerRadius: size * 0.14, style: .continuous)
                .fill(Palette.cardHi)
                .overlay(RoundedRectangle(cornerRadius: size * 0.14, style: .continuous).strokeBorder(Palette.brass.opacity(0.35), lineWidth: 1))
                .frame(width: size * 0.78, height: size * 0.52)
                .offset(y: size * 0.2)
            Capsule().fill(Palette.brass).frame(width: size * 0.06, height: size * 0.16).offset(y: size * 0.2)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct ArcShackle: Shape {
    var open = false
    func path(in r: CGRect) -> Path {
        var p = Path()
        let radius = r.width / 2
        let center = CGPoint(x: r.midX, y: r.minY + radius)
        let lift: CGFloat = open ? r.height * 0.25 : 0
        p.move(to: CGPoint(x: r.minX, y: r.maxY - lift))
        p.addLine(to: CGPoint(x: r.minX, y: center.y - lift))
        p.addArc(center: CGPoint(x: center.x, y: center.y - lift), radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: open ? center.y : r.maxY))
        return p
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
                        .background(Circle().fill(on ? Palette.brass : Color.white.opacity(0.04)))
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
