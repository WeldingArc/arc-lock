// What the shield's button does. There is exactly one button, and it only closes the blocked app:
// no "5 more minutes", no "ignore limit". That's the point. Pressing it also re-checks the blocks, so a shield whose
// time is really up (iOS missed a callback, e.g. a time-out's break end) lifts without opening Arc Lock.
import ManagedSettings

final class ShieldActionExtension: ShieldActionDelegate {
    override func handle(action: ShieldAction, for application: ApplicationToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        closeAndRecheck(completionHandler)
    }
    override func handle(action: ShieldAction, for webDomain: WebDomainToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        closeAndRecheck(completionHandler)
    }
    override func handle(action: ShieldAction, for category: ActivityCategoryToken,
                         completionHandler: @escaping (ShieldActionResponse) -> Void) {
        closeAndRecheck(completionHandler)
    }

    private func closeAndRecheck(_ completionHandler: @escaping (ShieldActionResponse) -> Void) {
        let (state, _) = Engine.housekeep()
        Monitoring.finishBreaks(state)
        Engine.reconcile(StateStore.load())
        completionHandler(.close)
    }
}
