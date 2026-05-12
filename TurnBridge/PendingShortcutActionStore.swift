import Foundation

enum PendingShortcutAction: String {
    case toggle
    case connect
    case disconnect
}

extension Notification.Name {
    static let pendingShortcutActionDidChange = Notification.Name("pendingShortcutActionDidChange")
}

enum PendingShortcutActionStore {
    private static let suiteName = "group.com.prodject.vbridge"
    private static let key = "pending.shortcut.action"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    static func store(_ action: PendingShortcutAction) {
        defaults?.set(action.rawValue, forKey: key)
        defaults?.synchronize()
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
