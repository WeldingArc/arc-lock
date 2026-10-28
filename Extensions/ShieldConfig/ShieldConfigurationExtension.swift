// The screen iOS shows over a blocked app or website. It says which block holds it and when it ends —
// and offers no way around it (the only button closes the app).
import FamilyControls
import Foundation
import ManagedSettings
import ManagedSettingsUI
import UIKit

final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        make(Holder.find(app: application.token, category: nil, web: nil, shown: application.localizedDisplayName))
    }
    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        make(Holder.find(app: application.token, category: category.token, web: nil, shown: application.localizedDisplayName))
    }
    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        make(Holder.find(app: nil, category: nil, web: webDomain.token, shown: webDomain.domain))
    }
    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        make(Holder.find(app: nil, category: category.token, web: webDomain.token, shown: webDomain.domain))
    }

    private func make(_ holder: Holder?) -> ShieldConfiguration {
        // the chosen theme (Settings › Appearance), with its phone mark — the lock shut
        let theme = ArcTheme.current, c = theme.colors
        let ink = UIColor(hex: c.ink), muted = UIColor(hex: c.muted), brass = UIColor(hex: c.accent), night = UIColor(hex: c.night)
        let title: String, subtitle: String
        if let h = holder {
            let when = Fmt.moment(h.until)
            let reason: String
            switch h.kind {
            case .limit:
                title = L("This limit is used up")
                reason = L("It unlocks at %@.", when)
            case .timeout:
                title = L("Time for a break")
                reason = L("Back at %@.", when)
            case .schedule, .session:
                title = L("Locked until %@", when)
                reason = L("This block ends on its own.")
            case .place:
                if h.until == .distantFuture {
                    title = L("Locked while you're here")
                    reason = L("This block ends when you leave.")
                } else {
                    title = L("Locked until %@", when)
                    reason = L("This block ends on its own.")
                }
            }
            subtitle = "\(h.name)\n\(reason)"
        } else {
            title = L("Locked by Arc Lock")
            subtitle = L("This block ends on its own. If it should be over, open Arc Lock to refresh.")
        }
        return ShieldConfiguration(
            backgroundBlurStyle: theme.isLight ? .systemUltraThinMaterialLight : .systemUltraThinMaterialDark,
            backgroundColor: night.withAlphaComponent(0.94),
            icon: UIImage(named: "ShieldMark-\(theme.rawValue)") ?? UIImage(named: "ShieldMark"),
            title: .init(text: title, color: ink),
            subtitle: .init(text: subtitle, color: muted),
            primaryButtonLabel: .init(text: L("Close"), color: night),
            primaryButtonBackgroundColor: brass,
            secondaryButtonLabel: nil)
    }
}

/// Which block is holding something, and until when (the latest end wins: that's when it really opens).
struct Holder {
    enum Kind { case schedule, limit, timeout, session, place }
    let name: String
    let until: Date
    let kind: Kind

    /// `shown` = the blocked app's or site's own name (iOS gives it to this screen): what a block without a typed name
    /// is called here.
    static func find(app: ApplicationToken?, category: ActivityCategoryToken?, web: WebDomainToken?, shown: String? = nil,
                     now: Date = Date(), calendar: Calendar = .current) -> Holder? {
        let state = StateStore.load()
        func holds(_ s: FamilyActivitySelection) -> Bool {
            if let a = app, s.applicationTokens.contains(a) { return true }
            if let c = category, s.categoryTokens.contains(c) { return true }
            if let w = web, s.webDomainTokens.contains(w) { return true }
            return false
        }
        var found: [Holder] = []
        for rule in state.rules where holds(rule.selection) {
            let status = Engine.status(rule, now: now, calendar: calendar)
            // a place block running until you leave has no end time: it holds for as long as you're there
            let untilLeave: Date? = { if case .atPlace = status { return .distantFuture }; return nil }()
            if let until = status.blockingUntil ?? untilLeave {
                let kind: Kind = switch rule.plan.kind {
                case .limit: .limit
                case .timeout: .timeout
                case .place: .place
                case .schedule: .schedule
                }
                let name = rule.plan.hasName ? rule.plan.displayName : (shown.flatMap { $0.isEmpty ? nil : $0 } ?? rule.plan.displayName)
                found.append(Holder(name: name, until: until, kind: kind))
            }
        }
        if let s = state.session, s.endsAt > now, holds(s.selection) {
            found.append(Holder(name: L("Block now"), until: s.endsAt, kind: .session))
        }
        return found.max(by: { $0.until < $1.until })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
