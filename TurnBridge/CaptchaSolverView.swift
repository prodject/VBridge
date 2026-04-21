import SwiftUI
import WebKit

struct CaptchaSolverView: View {
    let request: CaptchaRequest
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    private var captchaURL: URL? {
        URL(string: request.url)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Text("Manual Captcha")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text(request.mode == .proxy ? "Proxy fallback" : "Image fallback")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(request.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 8)

                if let captchaURL {
                    CaptchaWebView(url: captchaURL)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.12), radius: 18, x: 0, y: 8)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text("Invalid captcha URL")
                            .font(.headline)
                        Text("The extension published an invalid manual fallback payload.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Text(request.url)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if let captchaURL {
                    Button("Open in Browser") {
                        openURL(captchaURL)
                    }
                    .font(.footnote.weight(.semibold))
                }
            }
            .padding()
            .navigationTitle("Captcha")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                        onClose()
                    }
                }
            }
        }
    }
}

struct CaptchaWebView: View {
    let url: URL

    var body: some View {
#if os(iOS)
        UIKitCaptchaWebView(url: url)
#elseif os(macOS)
        AppKitCaptchaWebView(url: url)
#endif
    }
}

#if os(iOS)
private struct UIKitCaptchaWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard uiView.url != url else { return }
        uiView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {}
}
#endif

#if os(macOS)
private struct AppKitCaptchaWebView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard nsView.url != url else { return }
        nsView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate {}
}
#endif
