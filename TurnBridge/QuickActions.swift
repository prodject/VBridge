import UIKit

enum VBridgeQuickActionType {
    static let toggle = "com.prodject.vbridge.quickaction.toggle"
    static let connect = "com.prodject.vbridge.quickaction.connect"
    static let disconnect = "com.prodject.vbridge.quickaction.disconnect"

    static func register() {
        UIApplication.shared.shortcutItems = [
            makeItem(type: connect, title: "Connect VPN", systemImageName: "lock.shield"),
            makeItem(type: disconnect, title: "Disconnect VPN", systemImageName: "lock.open"),
            makeItem(type: toggle, title: "Toggle VPN", systemImageName: "arrow.2.circlepath")
        ]
    }

    static func handle(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
        guard let action = pendingAction(for: shortcutItem.type) else {
            return false
        }
        PendingShortcutActionStore.store(action)
        return true
    }

    private static func pendingAction(for type: String) -> PendingShortcutAction? {
        switch type {
        case toggle:
            return .toggle
        case connect:
            return .connect
        case disconnect:
            return .disconnect
        default:
            return nil
        }
    }

    private static func makeItem(type: String, title: String, systemImageName: String) -> UIApplicationShortcutItem {
        UIApplicationShortcutItem(
            type: type,
            localizedTitle: title,
            localizedSubtitle: nil,
            icon: UIApplicationShortcutIcon(systemImageName: systemImageName),
            userInfo: nil
        )
    }
}

final class VBridgeAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(VBridgeQuickActionType.handle(shortcutItem))
    }
}
