import XCTest
@testable import Moshpit

final class NativeRDPTrustTests: XCTestCase {
    func testTrustRejectsUnverifiedAndRedirection() {
        let approved = String(repeating: "ab", count: 32)
        let changed = "ac" + String(approved.dropFirst(2))
        XCTAssertFalse(NativeRDPTrust.accepts(expectedHost: "server", actualHost: "evil", trusted: true, fingerprint: approved, approved: approved))
        XCTAssertFalse(NativeRDPTrust.accepts(expectedHost: "server", actualHost: "server", trusted: false, fingerprint: approved, approved: nil))
        XCTAssertTrue(NativeRDPTrust.accepts(expectedHost: "server", actualHost: "SERVER", trusted: false, fingerprint: approved.uppercased(), approved: approved))
        XCTAssertFalse(NativeRDPTrust.accepts(expectedHost: "server", actualHost: "server", trusted: true, fingerprint: changed, approved: approved))
        XCTAssertFalse(NativeRDPTrust.accepts(expectedHost: "server", actualHost: "server", trusted: true, fingerprint: nil, approved: approved))
    }

    func testFingerprintAcceptsWindowsHexAndSeparatedFormats() {
        let server = Array(repeating: "ab", count: 32).joined(separator: ":")
        XCTAssertTrue(NativeRDPTrust.matchesFingerprint(String(repeating: "AB", count: 32), expected: server))
        XCTAssertTrue(NativeRDPTrust.matchesFingerprint("\n" + Array(repeating: "AB", count: 32).joined(separator: "- ") + "\t", expected: server))
    }

    func testFingerprintRejectsMalformedOrDifferentDigest() {
        let server = String(repeating: "ab", count: 32)
        XCTAssertFalse(NativeRDPTrust.matchesFingerprint(String(server.dropLast()), expected: server))
        XCTAssertFalse(NativeRDPTrust.matchesFingerprint("g" + String(server.dropFirst()), expected: server))
        XCTAssertFalse(NativeRDPTrust.matchesFingerprint("c" + String(server.dropFirst()), expected: server))
    }
}
