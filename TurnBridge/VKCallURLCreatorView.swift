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

enum VKAuthSessionStore {
    private static let service = "app.vbridge.vk-auth"
    private static let account = "vk-calls-access-token"

    static func loadAccessToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    static func saveAccessToken(_ token: String) {
        let data = Data(token.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var insertQuery = baseQuery
            insertQuery[kSecValueData as String] = data
            SecItemAdd(insertQuery as CFDictionary, nil)
        }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct VKAuthorizationView: View {
    let onSuccess: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var statusText = "Open VK authorization and confirm the account that should be saved."
    @State private var isCompleting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VKCallURLOAuthWebView(
                    onToken: { token in
                        complete(with: token)
                    },
                    onStatus: { status in
                        statusText = status
                    }
                )

                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(12)
            }
            .navigationTitle("VK Authorization")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                        onCancel()
                    }
                    .disabled(isCompleting)
                }
            }
        }
    }

    private func complete(with token: String) {
        guard !isCompleting else { return }
        isCompleting = true
        statusText = "Saving VK session..."

        Task {
            await MainActor.run {
                VKAuthSessionStore.saveAccessToken(token)
                dismiss()
                onSuccess()
            }
        }
    }
}

private struct VKCallURLOAuthWebView: UIViewRepresentable {
    let onToken: (String) -> Void
    let onStatus: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onToken: onToken, onStatus: onStatus)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        if let url = VKCallsStartAPI.authorizeURL {
            webView.load(URLRequest(url: url))
        } else {
            onStatus("Failed to build VK authorization URL.")
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onToken: (String) -> Void
        let onStatus: (String) -> Void
        weak var webView: WKWebView?
        private var didFinish = false

        init(onToken: @escaping (String) -> Void, onStatus: @escaping (String) -> Void) {
            self.onToken = onToken
            self.onStatus = onStatus
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               let token = VKCallsStartAPI.accessToken(from: url),
               !didFinish {
                didFinish = true
                decisionHandler(.cancel)
                onToken(token)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            if url.host == "id.vk.ru" {
                onStatus("Confirm the VK account that should create the call.")
            } else if url.host == VKCallsStartAPI.redirectHost {
                onStatus("Authorization completed.")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onStatus("Navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onStatus("Navigation failed: \(error.localizedDescription)")
        }
    }
}
