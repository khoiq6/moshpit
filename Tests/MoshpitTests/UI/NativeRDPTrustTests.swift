import XCTest
@testable import Moshpit

final class NativeRDPTrustTests: XCTestCase {
    func testTrustRejectsUnverifiedAndRedirection() {
        XCTAssertFalse(NativeRDPTrust.accepts(expectedHost: "server", actualHost: "evil", trusted: true, fingerprint: "aa", approved: nil))
        XCTAssertFalse(NativeRDPTrust.accepts(expectedHost: "server", actualHost: "server", trusted: false, fingerprint: "aa", approved: nil))
        XCTAssertTrue(NativeRDPTrust.accepts(expectedHost: "server", actualHost: "SERVER", trusted: false, fingerprint: "AA", approved: "aa"))
        XCTAssertFalse(NativeRDPTrust.accepts(expectedHost: "server", actualHost: "server", trusted: true, fingerprint: "bb", approved: "aa"))
        XCTAssertFalse(NativeRDPTrust.accepts(expectedHost: "server", actualHost: "server", trusted: true, fingerprint: nil, approved: "aa"))
    }
}
