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

@MainActor
final class CaptchaBridge: ObservableObject {
    @Published var activeRequest: CaptchaRequest?

    private let defaults: UserDefaults?
    private let storageKey = "captcha.pending.request"
    private var monitoringTask: Task<Void, Never>?

    init() {
        if let groupID = SharedLogger.appGroupID {
            defaults = UserDefaults(suiteName: groupID)
        } else {
            defaults = nil
        }
        refresh()
        startMonitoring()
    }

    deinit {
        monitoringTask?.cancel()
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
                activeRequest = request
                if let direct = request.directURL, !direct.isEmpty {
                    SharedLogger.info("Captcha request received: \(request.mode.rawValue) -> \(request.url) (direct: \(direct))")
                } else {
                    SharedLogger.info("Captcha request received: \(request.mode.rawValue) -> \(request.url)")
                }
            }
        } catch {
            SharedLogger.error("Failed to decode captcha request: \(error.localizedDescription)")
            activeRequest = nil
        }
    }

    func clear() {
        guard let defaults else {
            activeRequest = nil
            return
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
    }

    private func startMonitoring() {
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
    }
}
