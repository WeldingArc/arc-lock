// The usage line under a daily limit or a time-out. Drawn by the report extension on a device; the app draws the
// same view with sample numbers for demo screenshots.
import SwiftUI

struct UsageSummary: Equatable {
    /// Minutes counted today (for a daily limit: since `since`, plus time carried over by a change).
    var minutes: Int
    /// The daily limit, when the block is one.
    var limit: Int?
    /// When a daily limit started counting, if not at midnight (it was created or changed today).
    var since: Date?

    static func context(slot: Int) -> String { "slot.\(slot)" }
}

struct UsageView: View {
    let usage: UsageSummary

    private static let sage = Color(.sRGB, red: 0x8F / 255, green: 0xB3 / 255, blue: 0xA0 / 255)
    private static let rose = Color(.sRGB, red: 0xD4 / 255, green: 0x9A / 255, blue: 0x8C / 255)
    private static let faint = Color(.sRGB, red: 0x6B / 255, green: 0x73 / 255, blue: 0x85 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let limit = usage.limit, limit > 0 {
                let part = min(1, Double(usage.minutes) / Double(limit))
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.07))
                        if part > 0 {
                            Capsule().fill(part >= 1 ? Self.rose : Self.sage).frame(width: max(5, g.size.width * part))
                        }
                    }
                }
                .frame(height: 5)
            }
            Text(caption)
                .font(.custom("Pretendard-Regular", size: 12, relativeTo: .caption))
                .foregroundStyle(Self.faint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private var caption: String {
        let used = Self.duration(usage.minutes)
        guard let limit = usage.limit else {
            return usage.minutes == 0 ? String(localized: "Not used yet today") : String(localized: "\(used) used today")
        }
        let left = max(0, limit - usage.minutes)
        let leftText = left == 0 ? String(localized: "none left") : String(localized: "\(Self.duration(left)) left")
        if let since = usage.since {
            return String(localized: "\(used) since \(since.formatted(date: .omitted, time: .shortened)) · \(leftText)")
        }
        return String(localized: "\(used) used today · \(leftText)")
    }

    /// "0 min", "42 min", "1 hr 5 min".
    static func duration(_ minutes: Int) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = minutes >= 60 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .short
        f.zeroFormattingBehavior = minutes == 0 ? .default : .dropAll
        return f.string(from: TimeInterval(minutes * 60)) ?? "\(minutes) min"
    }
}
