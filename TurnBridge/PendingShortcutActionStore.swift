import Foundation

enum PendingShortcutAction: String {
    case toggle
    case connect
    case disconnect
    case reconnect
}

extension Notification.Name {
    static let pendingShortcutActionDidChange = Notification.Name("pendingShortcutActionDidChange")
}

enum PendingShortcutActionStore {
    private static let key = "pending.shortcut.action"

    private static var defaults: UserDefaults? {
        SharedLogger.sharedUserDefaults()
    }

    static func store(_ action: PendingShortcutAction) {
        guard let defaults else {
            SharedLogger.debug("Shortcut action ignored: shared App Group defaults unavailable")
            return
        }
        defaults.set(action.rawValue, forKey: key)
        defaults.synchronize()
        NotificationCenter.default.post(name: .pendingShortcutActionDidChange, object: nil)
    }

    static func consume() -> PendingShortcutAction? {
        guard let defaults else { return nil }
        defer {
            defaults.removeObject(forKey: key)
            defaults.synchronize()
        }
        guard let rawValue = defaults.string(forKey: key) else { return nil }
        return PendingShortcutAction(rawValue: rawValue)
    }
}
