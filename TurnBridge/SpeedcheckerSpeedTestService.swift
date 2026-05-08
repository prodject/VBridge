import Foundation
import CoreLocation

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
        return nil
#endif
    }
}

#if canImport(SpeedcheckerSDK)
private final class Runner: NSObject, InternetSpeedTestDelegate, CLLocationManagerDelegate {
    private var test: InternetSpeedTest?
    private var continuation: CheckedContinuation<SpeedcheckerMeasurementResult?, Never>?
    private var finished = false
    private var didStartSpeedTest = false

    private let locationManager = CLLocationManager()
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
        DispatchQueue.main.async {
            self.prepareLocationAndStartTest()
        }
    }

    private func prepareLocationAndStartTest() {
        locationManager.delegate = self

        guard CLLocationManager.locationServicesEnabled() else {
            SharedLogger.warning("Location services are disabled; starting Speedchecker without location")
            startSpeedTestIfNeeded()
            return
        }

        let status = authorizationStatus()

        switch status {
        case .notDetermined:
            SharedLogger.info("Requesting location authorization before Speedchecker test")
            locationManager.requestWhenInUseAuthorization()

            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }

                if !self.didStartSpeedTest {
                    SharedLogger.warning("Location authorization timeout; starting Speedchecker anyway")
                    self.startSpeedTestIfNeeded()
                }
            }

        case .authorizedAlways, .authorizedWhenInUse:
            SharedLogger.info("Location authorization available; starting Speedchecker test")
            startSpeedTestIfNeeded()

        case .denied, .restricted:
            SharedLogger.warning("Location authorization denied/restricted; starting Speedchecker without location")
            startSpeedTestIfNeeded()

        @unknown default:
            SharedLogger.warning("Unknown location authorization status; starting Speedchecker anyway")
            startSpeedTestIfNeeded()
        }
    }

    private func authorizationStatus() -> CLAuthorizationStatus {
        if #available(iOS 14.0, *) {
            return locationManager.authorizationStatus
        } else {
            return CLLocationManager.authorizationStatus()
        }
    }

    private func startSpeedTestIfNeeded() {
        guard !didStartSpeedTest else {
            return
        }

        didStartSpeedTest = true

        let test = InternetSpeedTest(delegate: self)
        self.test = test

        SharedLogger.info("Speedchecker SDK test starting")

        // Compatible with speedchecker-sdk-ios 1.8.x and newer 2.x APIs.
        // 1.8.x has start(...) / startTest(...)
        // 2.x has start(...) / startFreeTest(...)
        test.start { error in
            switch error {
            case .ok:
                break

            default:
                SharedLogger.warning("Speedchecker SDK start failed: \(String(describing: error))")
                self.finish(nil)
            }
        }
    }

    func internetTestError(error: SpeedTestError) {
        SharedLogger.warning("Speedchecker SDK error: \(String(describing: error))")
        finish(nil)
    }

    func internetTestFinish(result: SpeedTestResult) {
        let downloadMbps = result.downloadSpeed.mbps
        let uploadMbps = result.uploadSpeed.mbps

        let sdkISPName = clean(result.ispName)
        let sdkIPAddress = clean(result.ipAddress)

        Task { [weak self] in
            guard let self else { return }

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

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status: CLAuthorizationStatus

        if #available(iOS 14.0, *) {
            status = manager.authorizationStatus
        } else {
            status = CLLocationManager.authorizationStatus()
        }

        SharedLogger.info("Speedchecker location authorization changed: \(status.rawValue)")

        switch status {
        case .authorizedAlways, .authorizedWhenInUse, .denied, .restricted:
            startSpeedTestIfNeeded()

        case .notDetermined:
            break

        @unknown default:
            startSpeedTestIfNeeded()
        }
    }

    private func finish(_ result: SpeedcheckerMeasurementResult?) {
        guard !finished else {
            return
        }

        finished = true

        let continuation = self.continuation
        self.continuation = nil
        self.test = nil
        self.locationManager.delegate = nil

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
}
#endif