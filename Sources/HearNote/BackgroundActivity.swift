#if os(macOS)
import Foundation

/// One lease per user-requested operation. A task retains its lease until it
/// actually returns, so cancellation or replacement cannot release another
/// operation's protection. The last reference balances beginActivity.
///
/// This permits normal system idle sleep; it only prevents App Nap from
/// throttling active work when the app's windows are hidden.
/// https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheAppLevel.html
final class BackgroundActivity: @unchecked Sendable {
    // Immutable ownership: endActivity runs exactly once, from deinit.
    private let token: NSObjectProtocol

    init(reason: String) {
        token = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: reason
        )
    }

    deinit {
        ProcessInfo.processInfo.endActivity(token)
    }
}
#endif
