import SwiftUI

struct CaptchaSolverView: View {
    let request: CaptchaRequest
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var didOpenBrowser = false

    private var captchaURL: URL? { URL(string: request.url) }

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

                VStack(spacing: 10) {
                    Image(systemName: "safari.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.blue)
                    Text("The captcha page opens in your browser.")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("If it does not open automatically, use the button below.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)

                Text(request.url)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if let captchaURL {
                    Button("Open in Browser") {
                        openBrowser(captchaURL)
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
            .task {
                guard !didOpenBrowser, let captchaURL else { return }
                didOpenBrowser = true
                openBrowser(captchaURL)
            }
        }
    }

    private func openBrowser(_ url: URL) {
        _ = openURL(url)
    }
}
