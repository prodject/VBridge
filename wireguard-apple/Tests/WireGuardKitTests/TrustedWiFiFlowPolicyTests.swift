import XCTest
@testable import WireGuardKit

final class TrustedWiFiFlowPolicyTests: XCTestCase {
    func testLeavingAndReturningToTrustedWiFi() {
        let networks: [String?] = ["Home", nil, "Cafe", "Home"]
        XCTAssertEqual(networks.map {
            TrustedWiFiFlowPolicy.shouldBypass(enabled: true, flowConnect: true,
                                               trustedSSIDs: ["Home"], currentSSID: $0)
        }, [true, false, false, true])
    }

    func testBothSwitchesAreRequired() {
        for switches in [(false, true), (true, false), (false, false)] {
            XCTAssertFalse(TrustedWiFiFlowPolicy.shouldBypass(enabled: switches.0, flowConnect: switches.1,
                                                             trustedSSIDs: ["Home"], currentSSID: "Home"))
        }
    }

    func testSSIDMatchingIsExactAndMissingInformationDoesNotBypass() {
        let names: [String?] = [nil, "", "home", "Home-Guest"]
        for name in names {
            XCTAssertFalse(TrustedWiFiFlowPolicy.shouldBypass(enabled: true, flowConnect: true,
                                                             trustedSSIDs: ["Home"], currentSSID: name))
        }
        XCTAssertFalse(TrustedWiFiFlowPolicy.shouldBypass(enabled: true, flowConnect: true,
                                                         trustedSSIDs: [], currentSSID: "Home"))
    }
}
