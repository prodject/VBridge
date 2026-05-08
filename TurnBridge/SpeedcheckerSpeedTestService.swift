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
            let runner = Runner(continuation: continuation)
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
    private let locationManager = CLLocationManager()

    init(continuation: CheckedContinuation<SpeedcheckerMeasurementResult?, Never>) {
        self.continuation = continuation
    }

    func start() {
        if CLLocationManager.locationServicesEnabled() {
            DispatchQueue.main.async {
                self.locationManager.delegate = self
                self.locationManager.requestWhenInUseAuthorization()
            }
        }

        let test = InternetSpeedTest(delegate: self)
        self.test = test
        SharedLogger.info("Speedchecker SDK free test starting")
        test.startFreeTest { error in
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
        let mapped = SpeedcheckerMeasurementResult(
            downloadMbps: result.downloadSpeed.mbps,
            uploadMbps: result.uploadSpeed.mbps,
            ispName: result.ispName,
            ipAddress: result.ipAddress
        )
        SharedLogger.info(
            String(
                format: "Speedchecker SDK finished: download=%@ upload=%@ isp=%@",
                mapped.downloadMbps.map { String(format: "%.1f", $0) } ?? "--",
                mapped.uploadMbps.map { String(format: "%.1f", $0) } ?? "--",
                mapped.ispName ?? "unknown"
            )
        )
        finish(mapped)
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
        SharedLogger.info("Speedchecker location authorization changed: \(manager.authorizationStatus.rawValue)")
    }

    private func finish(_ result: SpeedcheckerMeasurementResult?) {
        guard !finished else { return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        self.test = nil
        continuation?.resume(returning: result)
    }
}
#endif
