import Foundation
import Combine

enum CaptchaRequestMode: String, Codable {
    case proxy
    case image
}

struct CaptchaRequest: Codable, Identifiable, Equatable {
    let id: String
    let mode: CaptchaRequestMode
    let url: String
    let directURL: String?
    let message: String

    enum CodingKeys: String, CodingKey {
        case id
        case mode
        case url
        case directURL = "direct_url"
        case message
    }
}

enum CaptchaBridgeNotification {
    static let requestDidChange = CFNotificationName(rawValue: "com.prodject.vbridge.captcha.pending.request.changed" as CFString)
}

private func captchaBridgeDarwinCallback(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    guard let observer else { return }
    let token = Unmanaged<NotificationObserver>.fromOpaque(observer).takeUnretainedValue()
    token.fire()
}

@MainActor
final class CaptchaBridge: ObservableObject {
    @Published var activeRequest: CaptchaRequest?

    private let defaults: UserDefaults?
    private let storageKey = "captcha.pending.request"
    private var monitoringTask: Task<Void, Never>?
    private var notificationObserver: AnyObject?

    init() {
        if let groupID = SharedLogger.appGroupID {
            defaults = UserDefaults(suiteName: groupID)
        } else {
            defaults = nil
        }
        refresh()
        startMonitoring()
        startNotificationObserver()
    }

    deinit {
        monitoringTask?.cancel()
        if let notificationObserver {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(notificationObserver).toOpaque(),
                CaptchaBridgeNotification.requestDidChange,
                nil
            )
        }
    }

    func refresh() {
        guard let defaults else {
            activeRequest = nil
            return
        }

        guard let data = defaults.data(forKey: storageKey) else {
            if activeRequest != nil {
                activeRequest = nil
            }
            return
        }

        do {
            let request = try JSONDecoder().decode(CaptchaRequest.self, from: data)
            if activeRequest != request {
                if let current = activeRequest {
                    UserNotificationDispatcher.shared.clearCaptchaNotification(requestID: current.id)
                }
                activeRequest = request
                if let direct = request.directURL, !direct.isEmpty {
                    SharedLogger.info("Captcha request received: \(request.mode.rawValue) -> \(request.url) (direct: \(direct))")
                } else {
                    SharedLogger.info("Captcha request received: \(request.mode.rawValue) -> \(request.url)")
                }
                UserNotificationDispatcher.shared.notifyCaptchaIfNeeded(request: request)
            }
        } catch {
            SharedLogger.error("Failed to decode captcha request: \(error.localizedDescription)")
            if let current = activeRequest {
                UserNotificationDispatcher.shared.clearCaptchaNotification(requestID: current.id)
            }
            activeRequest = nil
        }
    }

    func clear() {
        guard let defaults else {
            if let current = activeRequest {
                UserNotificationDispatcher.shared.clearCaptchaNotification(requestID: current.id)
            }
            activeRequest = nil
            return
        }

        if let current = activeRequest {
            UserNotificationDispatcher.shared.clearCaptchaNotification(requestID: current.id)
        }
        defaults.removeObject(forKey: storageKey)
        SharedLogger.info("Captcha request cleared")
        activeRequest = nil
    }

    func store(_ request: CaptchaRequest) {
        guard let defaults else { return }

        guard let data = try? JSONEncoder().encode(request) else {
            SharedLogger.error("Failed to encode captcha request")
            return
        }

        defaults.set(data, forKey: storageKey)
        activeRequest = request
        UserNotificationDispatcher.shared.notifyCaptchaIfNeeded(request: request)
    }

    private func startMonitoring() {
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
    }

    private func startNotificationObserver() {
        let observer = NotificationObserver { [weak self] in
            Task { @MainActor in
                self?.refresh()
            }
        }
        notificationObserver = observer

        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            Unmanaged.passUnretained(observer).toOpaque(),
            captchaBridgeDarwinCallback,
            CaptchaBridgeNotification.requestDidChange.rawValue,
            nil,
            .deliverImmediately
        )
    }
}

private final class NotificationObserver {
    private let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    func fire() {
        handler()
    }
}
