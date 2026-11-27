import XCTest
@testable import Moshpit

final class WindowsGatewayAddressTests: XCTestCase {
    func testAcceptsHTTPSWithoutCredentials() {
        XCTAssertNotNil(WindowsGatewayAddress.parse("https://rdp.example.com/guacamole/"))
        XCTAssertNotNil(WindowsGatewayAddress.parse(" https://rdp.example.com:8443/guacamole/ "))
        for url in ["http://rdp.example.com", "https://u:p@rdp.example.com", "https://rdp.example.com/?token=x", "https://rdp.example.com/#secret", "10.0.0.1:3389", "https://rdp.example.com:65536"] {
            XCTAssertNil(WindowsGatewayAddress.parse(url), url)
        }
    }

    func testOriginChecksPortSchemeAndHostname() throws {
        let base = try XCTUnwrap(URL(string: "https://rdp.example.com/guacamole/"))
        XCTAssertTrue(WindowsGatewayAddress.sameOrigin(base, try XCTUnwrap(URL(string: "https://rdp.example.com:443/guacamole/#/client/1"))))
        XCTAssertFalse(WindowsGatewayAddress.sameOrigin(base, try XCTUnwrap(URL(string: "https://rdp.example.com:8443/"))))
        XCTAssertFalse(WindowsGatewayAddress.sameOrigin(base, try XCTUnwrap(URL(string: "http://rdp.example.com/"))))
        XCTAssertFalse(WindowsGatewayAddress.sameOrigin(base, try XCTUnwrap(URL(string: "https://other.example.com/"))))
    }
}
