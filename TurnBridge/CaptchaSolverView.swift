import SwiftUI

struct CaptchaSolverView: View {
    let request: CaptchaRequest
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var didOpenBrowser = false
    @State private var tokenInput = ""
    @State private var tokenStatus: String?
    @State private var isSubmittingToken = false

    private var captchaURL: URL? { URL(string: request.url) }
    private var directURL: URL? {
        guard let direct = request.directURL, !direct.isEmpty else { return nil }
        return URL(string: direct)
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

                if let directURL {
                    Text(directURL.absoluteString)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Button("Open Direct Link") {
                        openBrowser(directURL)
                    }
                    .font(.footnote.weight(.semibold))
                }

                if request.mode == .proxy {
                    VStack(spacing: 8) {
                        TextField("Paste success_token", text: $tokenInput)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                            .font(.footnote.monospaced())
                            .textFieldStyle(.roundedBorder)

                        Button(isSubmittingToken ? "Submitting..." : "Submit Token") {
                            submitToken()
                        }
                        .disabled(isSubmittingToken || tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if let tokenStatus {
                            Text(tokenStatus)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
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

    private func submitToken() {
        let token = tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        guard let submitURL = URL(string: "http://localhost:8765/local-captcha-result") else { return }

        isSubmittingToken = true
        tokenStatus = nil

        var req = URLRequest(url: submitURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let formAllowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encodedToken = token.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? token
        req.httpBody = "token=\(encodedToken)".data(using: .utf8)

        URLSession.shared.dataTask(with: req) { _, response, error in
            DispatchQueue.main.async {
                isSubmittingToken = false
                if let error {
                    tokenStatus = "Submit failed: \(error.localizedDescription)"
                    return
                }
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200...299).contains(code) {
                    tokenStatus = "Token submitted. You can close this screen."
                } else {
                    tokenStatus = "Submit failed: HTTP \(code)"
                }
            }
        }.resume()
    }
}
