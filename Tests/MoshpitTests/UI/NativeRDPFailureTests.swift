import Darwin
import RDPKit
import XCTest
@testable import Moshpit

final class NativeRDPFailureTests: XCTestCase {
    func testFirstConnectionKeepsTheCauseOfFailure() {
        let cases: [(RDPConnectionFailure, String.LocalizationValue)] = [
            (.connect(error: RDPSocketError(errno: ECONNREFUSED)), "RDP port refused the connection"),
            (.credSSP(status: .logonFailure), "RDP sign-in failed"),
            (.credSSP(status: .logonTypeNotGranted), "RDP account is not allowed"),
            (.noFramePresented(framesReceived: 0, lastNotPresentedReason: nil), "RDP desktop did not appear"),
        ]
        for (failure, expected) in cases {
            XCTAssertEqual(WindowsWords.text(NativeRDPFailure.message(for: failure, showedDesktop: false)),
                           WindowsWords.text(expected))
        }
    }

    func testConnectionClosedBeforeDesktopIsDifferentFromInterruption() {
        XCTAssertEqual(WindowsWords.text(NativeRDPFailure.message(for: .connectionClosed, showedDesktop: false)),
                       WindowsWords.text("RDP connection closed before the desktop appeared"))
        XCTAssertEqual(WindowsWords.text(NativeRDPFailure.message(for: .connectionClosed, showedDesktop: true)),
                       WindowsWords.text("RDP connection was interrupted"))
    }
}
