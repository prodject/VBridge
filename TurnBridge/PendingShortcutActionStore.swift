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
    private static var didLogUnavailableWarning = false

    private static var defaults: UserDefaults? {
        guard let groupID = appGroupID else {
            return nil
        }
        return UserDefaults(suiteName: groupID)
    }

    private static var appGroupID: String? {
        let candidates = [
            "group.com.prodject.vbridge",
            Bundle.main.bundleIdentifier.map { "group.\($0.replacingOccurrences(of: ".network-extension", with: ""))" }
        ].compactMap { $0 }

        for candidate in candidates {
            if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: candidate) != nil {
                return candidate
            }
        }
        return nil
    }

    static var isAvailable: Bool {
        defaults != nil
    }

    private static func logUnavailableIfNeeded() {
        guard !didLogUnavailableWarning else { return }
        didLogUnavailableWarning = true
        NSLog("Shortcuts and widget control actions are unavailable in this build because the shared App Group container is missing.")
    }

    static func store(_ action: PendingShortcutAction) {
        guard let defaults else {
            logUnavailableIfNeeded()
            return
        }
        defaults.set(action.rawValue, forKey: key)
        defaults.synchronize()
        NotificationCenter.default.post(name: .pendingShortcutActionDidChange, object: nil)
    }

    static func consume() -> PendingShortcutAction? {
        guard let defaults else {
            logUnavailableIfNeeded()
            return nil
        }
        defer {
            defaults.removeObject(forKey: key)
            defaults.synchronize()
        }
        guard let rawValue = defaults.string(forKey: key) else { return nil }
        return PendingShortcutAction(rawValue: rawValue)
    }
}
