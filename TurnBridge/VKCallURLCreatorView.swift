import SwiftUI
import WebKit
import Security

enum VKCallURLCreatorError: LocalizedError {
    case invalidResponse
    case vkError(Int, String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "VK returned an unexpected response."
        case let .vkError(code, message):
            return "VK error \(code): \(message)"
        case let .network(message):
            return "Network error: \(message)"
        }
    }
}

enum VKCallsStartAPI {
    static let clientID = "6287487"
    static let apiVersion = "5.276"
    static let redirectHost = "oauth.vk.ru"
    static let redirectPath = "/blank.html"

    static var authorizeURL: URL? {
        URL(string: "https://oauth.vk.ru/authorize?client_id=\(clientID)&scope=calls&response_type=token")
    }

    static func accessToken(from url: URL) -> String? {
        guard url.host == redirectHost,
              url.path == redirectPath,
              let fragment = url.fragment else {
            return nil
        }
        for part in fragment.split(separator: "&") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2, pair[0] == "access_token", !pair[1].isEmpty {
                return String(pair[1])
            }
        }
        return nil
    }

    static func createCall(accessToken: String) async throws -> String {
        let hosts = ["api.vk.ru", "api.vk.com"]
        var lastNetworkError = "Unknown network error."

        for host in hosts {
            var components = URLComponents()
            components.scheme = "https"
            components.host = host
            components.path = "/method/calls.start"
            components.queryItems = [
                URLQueryItem(name: "v", value: apiVersion),
                URLQueryItem(name: "access_token", value: accessToken)
            ]
            guard let url = components.url else {
                throw VKCallURLCreatorError.invalidResponse
            }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 20

            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw VKCallURLCreatorError.invalidResponse
                }
                if let error = object["error"] as? [String: Any] {
                    let code = error["error_code"] as? Int ?? -1
                    let message = error["error_msg"] as? String ?? "unknown error"
                    throw VKCallURLCreatorError.vkError(code, message)
                }
                guard let response = object["response"] as? [String: Any],
                      let joinLink = response["join_link"] as? String,
                      !joinLink.isEmpty else {
                    throw VKCallURLCreatorError.invalidResponse
                }
                return joinLink
            } catch let error as VKCallURLCreatorError {
                throw error
            } catch {
                lastNetworkError = error.localizedDescription
            }
        }

        throw VKCallURLCreatorError.network(lastNetworkError)
    }
}

enum VKCookieStore {
    private static let service = "app.vbridge.vk-auth"
    private static let account = "vk-cookie"

    struct Stored: Codable {
        let cookieHeader: String
        let expiry: Date
        let savedAt: Date
    }

    @discardableResult
    static func save(cookieHeader: String, expiry: Date) -> Bool {
        let stored = Stored(cookieHeader: cookieHeader, expiry: expiry, savedAt: Date())
        guard let data = try? JSONEncoder().encode(stored) else { return false }

        SecItemDelete(baseQuery() as CFDictionary)
        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func load() -> Stored? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func isValid(now: Date = Date()) -> Bool {
        guard let stored = load() else { return false }
        return stored.expiry > now
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

struct VKAuthorizationView: View {
    let onSuccess: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VKAuthWebView { result in
            switch result {
            case let .harvested(cookieHeader, expiry):
                _ = VKCookieStore.save(cookieHeader: cookieHeader, expiry: expiry)
                dismiss()
                onSuccess()
            case .cancelled:
                dismiss()
                onCancel()
            }
        }
    }
}

enum VKAuthResult {
    case harvested(cookieHeader: String, expiry: Date)
    case cancelled
}

private struct VKAuthWebView: View {
    let onResult: (VKAuthResult) -> Void

    @State private var harvested = false
    @State private var statusText = "Sign in to VK. The session will be saved for call creation."

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("VK Authorization")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    onResult(.cancelled)
                }
                .font(.headline)
            }
            .padding()

            VKAuthWKWebView(
                onHarvested: { header, expiry in
                    guard !harvested else { return }
                    harvested = true
                    onResult(.harvested(cookieHeader: header, expiry: expiry))
                },
                onStatus: { statusText = $0 }
            )

            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(8)
        }
    }
}

private struct VKAuthWKWebView: UIViewRepresentable {
    let onHarvested: (_ cookieHeader: String, _ expiry: Date) -> Void
    let onStatus: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onHarvested: onHarvested, onStatus: onStatus)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        if let url = URL(string: "https://vk.ru/") {
            webView.load(URLRequest(url: url))
        }
        context.coordinator.startPolling()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopPolling()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onHarvested: (_ cookieHeader: String, _ expiry: Date) -> Void
        let onStatus: (String) -> Void
        weak var webView: WKWebView?
        private var timer: Timer?
        private var done = false

        init(onHarvested: @escaping (_ cookieHeader: String, _ expiry: Date) -> Void,
             onStatus: @escaping (String) -> Void) {
            self.onHarvested = onHarvested
            self.onStatus = onStatus
        }

        func startPolling() {
            timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
                self?.tryHarvest()
            }
        }

        func stopPolling() {
            timer?.invalidate()
            timer = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            tryHarvest()
        }

        private func tryHarvest() {
            guard !done, let store = webView?.configuration.websiteDataStore.httpCookieStore else { return }
            store.getAllCookies { [weak self] cookies in
                guard let self, !self.done else { return }
                var remixsid: HTTPCookie?
                var p: HTTPCookie?
                for cookie in cookies {
                    let domain = cookie.domain.hasPrefix(".") ? cookie.domain : "." + cookie.domain
                    if cookie.name == "remixsid", (domain.hasSuffix(".vk.com") || domain.hasSuffix(".vk.ru")) {
                        remixsid = cookie
                    }
                    if cookie.name == "p", (domain.hasSuffix(".login.vk.com") || domain.hasSuffix(".login.vk.ru")) {
                        p = cookie
                    }
                }
                guard let remixsid, let p else {
                    self.onStatus("Waiting for VK sign-in to finish...")
                    return
                }
                self.done = true
                self.stopPolling()
                let header = "remixsid=\(remixsid.value); p=\(p.value)"
                let fallback = Date().addingTimeInterval(30 * 24 * 3600)
                let expiry = min(remixsid.expiresDate ?? fallback, p.expiresDate ?? fallback)
                self.onStatus("VK session captured.")
                DispatchQueue.main.async {
                    self.onHarvested(header, expiry)
                }
            }
        }
    }
}

enum VKOAuthResult {
    case token(String)
    case needsLogin
    case failed(String)
    case cancelled
}

private enum VKOAuth {
    static func domain(forCookie name: String) -> String? {
        switch name {
        case "remixsid":
            return ".vk.ru"
        case "p":
            return ".login.vk.ru"
        default:
            return nil
        }
    }

    static func cookies(fromHeader header: String, expiry: Date) -> [HTTPCookie] {
        header.split(separator: ";").compactMap { pair in
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { return nil }
            let name = kv[0].trimmingCharacters(in: .whitespaces)
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, let domain = domain(forCookie: name) else { return nil }
            return HTTPCookie(properties: [
                .name: name,
                .value: value,
                .domain: domain,
                .path: "/",
                .secure: "TRUE",
                .expires: expiry
            ])
        }
    }
}

struct VKCallURLCreatorView: View {
    let onSuccess: (String) -> Void
    let onCancel: () -> Void
    let onNeedsLogin: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var done = false
    @State private var statusText = "Opening VK ID..."

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Create VK Call")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    finishCancelled()
                }
                .font(.headline)
            }
            .padding()

            VKOAuthWKWebView(
                onToken: { token in
                    Task { await createCall(token: token) }
                },
                onNeedsLogin: {
                    guard !done else { return }
                    done = true
                    dismiss()
                    onNeedsLogin()
                },
                onStatus: { statusText = $0 }
            )

            Text(statusText)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(8)
        }
    }

    private func finishCancelled() {
        guard !done else { return }
        done = true
        dismiss()
        onCancel()
    }

    private func createCall(token: String) async {
        await MainActor.run {
            statusText = "Creating the call..."
        }

        do {
            let link = try await VKCallsStartAPI.createCall(accessToken: token)
            await MainActor.run {
                guard !done else { return }
                done = true
                dismiss()
                onSuccess(link)
            }
        } catch {
            await MainActor.run {
                guard !done else { return }
                done = true
                dismiss()
                onNeedsLogin()
            }
        }
    }
}

private struct VKOAuthWKWebView: UIViewRepresentable {
    let onToken: (String) -> Void
    let onNeedsLogin: () -> Void
    let onStatus: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken, onNeedsLogin: onNeedsLogin, onStatus: onStatus)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()

        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "vkoauth")
        controller.addUserScript(WKUserScript(source: """
        (function() {
            var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vkoauth;
            if (!h) return;
            var of = window.fetch;
            window.fetch = function(input, init) {
                var url = typeof input === 'string' ? input : (input && input.url) || '';
                var p = of.apply(this, arguments);
                if (url.indexOf('act=connect_internal') >= 0) {
                    p.then(function(r) { return r.clone().text(); })
                     .then(function(t) { h.postMessage('gate:' + (t.indexOf('\"error\"') >= 0 ? 'error' : 'ok') + ' len=' + t.length); })
                     .catch(function() { h.postMessage('gate:unreadable'); });
                }
                return p;
            };
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        config.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.plantCookiesAndLoad()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let onToken: (String) -> Void
        let onNeedsLogin: () -> Void
        let onStatus: (String) -> Void
        weak var webView: WKWebView?
        private var finished = false

        init(onToken: @escaping (String) -> Void,
             onNeedsLogin: @escaping () -> Void,
             onStatus: @escaping (String) -> Void) {
            self.onToken = onToken
            self.onNeedsLogin = onNeedsLogin
            self.onStatus = onStatus
        }

        func plantCookiesAndLoad() {
            guard let webView, let url = VKCallsStartAPI.authorizeURL else { return }
            guard let stored = VKCookieStore.load(), stored.expiry > Date() else {
                onNeedsLogin()
                return
            }

            let cookies = VKOAuth.cookies(fromHeader: stored.cookieHeader, expiry: stored.expiry)
            let store = webView.configuration.websiteDataStore.httpCookieStore
            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                store.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main) { [weak self] in
                self?.onStatus("Opening VK ID...")
                webView.load(URLRequest(url: url))
            }
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               let token = VKCallsStartAPI.accessToken(from: url) {
                decisionHandler(.cancel)
                guard !finished else { return }
                finished = true
                onStatus("Token acquired.")
                onToken(token)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            if url.host == "id.vk.ru" {
                onStatus("Confirm the VK account for call creation.")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onStatus("Navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onStatus("Navigation failed: \(error.localizedDescription)")
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? String else { return }
            if body.hasPrefix("gate:error"), !finished {
                finished = true
                onNeedsLogin()
            }
        }
    }
}
