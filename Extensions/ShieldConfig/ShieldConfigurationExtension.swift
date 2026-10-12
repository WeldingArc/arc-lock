// The screen iOS shows over a blocked app or website. It says which block holds it and when it ends —
// and offers no way around it (the only button closes the app).
import FamilyControls
import Foundation
import ManagedSettings
import ManagedSettingsUI
import UIKit

final class ShieldConfigurationExtension: ShieldConfigurationDataSource {
    override func configuration(shielding application: Application) -> ShieldConfiguration {
        make(Holder.find(app: application.token, category: nil, web: nil))
    }
    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        make(Holder.find(app: application.token, category: category.token, web: nil))
    }
    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        make(Holder.find(app: nil, category: nil, web: webDomain.token))
    }
    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        make(Holder.find(app: nil, category: category.token, web: webDomain.token))
    }

    private func make(_ holder: Holder?) -> ShieldConfiguration {
        let ink = UIColor(red: 0.914, green: 0.902, blue: 0.875, alpha: 1)      // #E9E6DF
        let muted = UIColor(red: 0.604, green: 0.631, blue: 0.694, alpha: 1)    // #9AA1B1
        let brass = UIColor(red: 0.784, green: 0.663, blue: 0.416, alpha: 1)    // #C8A96A
        let night = UIColor(red: 0.055, green: 0.078, blue: 0.141, alpha: 1)    // #0E1424
        let title: String, subtitle: String
        if let h = holder {
            let when = Fmt.moment(h.until)
            switch h.kind {
            case .limit: title = L("Today's limit is used up")
            case .schedule, .session: title = L("Locked until %@", when)
            }
            let reason = h.kind == .limit ? L("It unlocks at %@.", when) : L("This block ends on its own.")
            subtitle = "\(h.name)\n\(reason)"
        } else {
            title = L("Locked by Arc Lock")
            subtitle = L("This block ends on its own. If it should be over, open Arc Lock to refresh.")
        }
        return ShieldConfiguration(
            backgroundBlurStyle: .systemUltraThinMaterialDark,
            backgroundColor: night.withAlphaComponent(0.94),
            icon: UIImage(named: "ShieldMark"),
            title: .init(text: title, color: ink),
            subtitle: .init(text: subtitle, color: muted),
            primaryButtonLabel: .init(text: L("Close"), color: night),
            primaryButtonBackgroundColor: brass,
            secondaryButtonLabel: nil)
    }
}

/// Which block is holding something, and until when (the latest end wins: that's when it really opens).
struct Holder {
    enum Kind { case schedule, limit, session }
    let name: String
    let until: Date
    let kind: Kind

    static func find(app: ApplicationToken?, category: ActivityCategoryToken?, web: WebDomainToken?,
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
            let status = Status.of(rule.plan, now: now, reachedAt: Marks.reachedAt(rule.id), calendar: calendar)
            if let until = status.blockingUntil {
                found.append(Holder(name: rule.plan.name, until: until, kind: rule.plan.kind == .limit ? .limit : .schedule))
            }
        }
        if let s = state.session, s.endsAt > now, holds(s.selection) {
            found.append(Holder(name: L("Block now"), until: s.endsAt, kind: .session))
        }
        return found.max(by: { $0.until < $1.until })
    }
}
