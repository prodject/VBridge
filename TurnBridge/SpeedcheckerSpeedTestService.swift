import Foundation

#if canImport(SpeedcheckerSDK)
import SpeedcheckerSDK
#endif

struct SpeedcheckerMeasurementResult {
    let downloadMbps: Double?
    let uploadMbps: Double?
    let ispName: String?
    let ipAddress: String?
}

final class SpeedcheckerSpeedTestService: NSObject {
#if canImport(SpeedcheckerSDK)
    private var runner: Runner?
#endif

    func runFreeTest() async -> SpeedcheckerMeasurementResult? {
#if canImport(SpeedcheckerSDK)
        return await withCheckedContinuation { continuation in
            let runner = Runner(continuation: continuation) { [weak self] in
                self?.runner = nil
            }

            self.runner = runner
            runner.start()
        }
#else
        SharedLogger.warning("Speedchecker SDK is unavailable at build time")
        return await fallbackOnlyResult()
#endif
    }

    private func fallbackOnlyResult() async -> SpeedcheckerMeasurementResult? {
        guard let fallback = await PublicIPInfoService().fetch() else {
            return nil
        }

        return SpeedcheckerMeasurementResult(
            downloadMbps: nil,
            uploadMbps: nil,
            ispName: fallback.ispName,
            ipAddress: fallback.ipAddress
        )
    }
}

#if canImport(SpeedcheckerSDK)
private final class Runner: NSObject, InternetSpeedTestDelegate {
    private var test: InternetSpeedTest?
    private var continuation: CheckedContinuation<SpeedcheckerMeasurementResult?, Never>?
    private var finished = false

    private let publicIPInfoService = PublicIPInfoService()
    private let onFinish: () -> Void

    init(
        continuation: CheckedContinuation<SpeedcheckerMeasurementResult?, Never>,
        onFinish: @escaping () -> Void
    ) {
        self.continuation = continuation
        self.onFinish = onFinish
    }

    func start() {
        // Give NEPacketTunnel/WireGuard a short moment to settle after VPN status becomes Connected.
        // Without this, Speedchecker 1.8.x often cancels while routes are still switching.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.startSpeedchecker()
        }
    }

    private func startSpeedchecker() {
        guard !finished else {
            return
        }

        let test = InternetSpeedTest(delegate: self)
        self.test = test

        SharedLogger.info("Speedchecker SDK test starting")

        // Compatible with speedchecker-sdk-ios 1.8.x and newer 2.x APIs.
        // 1.8.x exposes start(...) and startTest(...).
        // 2.x exposes start(...) and startFreeTest(...).
        test.start { [weak self] error in
            guard let self else {
                return
            }

            switch error {
            case .ok:
                break

            default:
                SharedLogger.warning("Speedchecker SDK start failed: \(Self.describe(error))")
                self.finishWithFallback(
                    downloadMbps: nil,
                    uploadMbps: nil,
                    reason: "start failed"
                )
            }
        }
    }

    func internetTestError(error: SpeedTestError) {
        SharedLogger.warning("Speedchecker SDK error: \(Self.describe(error))")

        finishWithFallback(
            downloadMbps: nil,
            uploadMbps: nil,
            reason: "SDK error"
        )
    }

    func internetTestFinish(result: SpeedTestResult) {
        let downloadMbps = result.downloadSpeed.mbps
        let uploadMbps = result.uploadSpeed.mbps

        let sdkISPName = clean(result.ispName)
        let sdkIPAddress = clean(result.ipAddress)

        Task { [weak self] in
            guard let self else {
                return
            }

            var finalISPName = sdkISPName
            var finalIPAddress = sdkIPAddress

            if finalISPName == nil || finalIPAddress == nil {
                SharedLogger.info("Speedchecker SDK returned empty ISP/IP; trying public IP fallback")

                if let fallback = await self.publicIPInfoService.fetch() {
                    finalISPName = finalISPName ?? fallback.ispName
                    finalIPAddress = finalIPAddress ?? fallback.ipAddress
                }
            }

            let mapped = SpeedcheckerMeasurementResult(
                downloadMbps: downloadMbps,
                uploadMbps: uploadMbps,
                ispName: finalISPName,
                ipAddress: finalIPAddress
            )

            SharedLogger.info(
                String(
                    format: "Speedchecker SDK finished: download=%@ upload=%@ isp=%@ ip=%@",
                    mapped.downloadMbps.map { String(format: "%.1f", $0) } ?? "--",
                    mapped.uploadMbps.map { String(format: "%.1f", $0) } ?? "--",
                    mapped.ispName ?? "unknown",
                    mapped.ipAddress ?? "unknown"
                )
            )

            self.finish(mapped)
        }
    }

    private func finishWithFallback(
        downloadMbps: Double?,
        uploadMbps: Double?,
        reason: String
    ) {
        Task { [weak self] in
            guard let self else {
                return
            }

            SharedLogger.warning("Speedchecker SDK returned no usable result, trying IP/ISP fallback: \(reason)")

            let fallback = await self.publicIPInfoService.fetch()

            let mapped = SpeedcheckerMeasurementResult(
                downloadMbps: downloadMbps,
                uploadMbps: uploadMbps,
                ispName: fallback?.ispName,
                ipAddress: fallback?.ipAddress
            )

            SharedLogger.info(
                String(
                    format: "Speedchecker fallback result: download=%@ upload=%@ isp=%@ ip=%@",
                    mapped.downloadMbps.map { String(format: "%.1f", $0) } ?? "--",
                    mapped.uploadMbps.map { String(format: "%.1f", $0) } ?? "--",
                    mapped.ispName ?? "unknown",
                    mapped.ipAddress ?? "unknown"
                )
            )

            self.finish(mapped)
        }
    }

    func internetTestReceived(servers: [SpeedTestServer]) {
        SharedLogger.info("Speedchecker SDK received \(servers.count) servers")
    }

    func internetTestSelected(server: SpeedTestServer, latency: Int, jitter: Int) {
        SharedLogger.info("Speedchecker SDK selected server latency=\(latency) jitter=\(jitter)")
    }

    func internetTestDownloadStart() { }
    func internetTestDownloadFinish() { }
    func internetTestDownload(progress: Double, speed: SpeedTestSpeed) { }

    func internetTestUploadStart() { }
    func internetTestUploadFinish() { }
    func internetTestUpload(progress: Double, speed: SpeedTestSpeed) { }

    private func finish(_ result: SpeedcheckerMeasurementResult?) {
        guard !finished else {
            return
        }

        finished = true

        let continuation = self.continuation
        self.continuation = nil
        self.test = nil

        continuation?.resume(returning: result)
        onFinish()
    }

    private func clean(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            return nil
        }

        let lowered = trimmed.lowercased()

        guard lowered != "unknown",
              lowered != "nil",
              lowered != "null",
              lowered != "--" else {
            return nil
        }

        return trimmed
    }

    private static func describe(_ error: SpeedTestError) -> String {
        switch error {
        case .ok:
            return "ok"

        case .invalidSettings:
            return "invalidSettings"

        case .invalidServers:
            return "invalidServers"

        case .inProgress:
            return "inProgress"

        case .failed:
            return "failed"

        case .notSaved:
            return "notSaved"

        case .cancelled:
            return "cancelled"

        case .locationUndefined:
            return "locationUndefined"

        @unknown default:
            return "unknown(rawValue=\(error.rawValue))"
        }
    }
}
#endif