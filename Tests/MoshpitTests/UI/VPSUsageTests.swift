import XCTest
@testable import Moshpit
final class VPSUsageTests: XCTestCase {
    func testUsage() {
        XCTAssertEqual(VPSUsage.parse("25.5 48 72\n")?.cpu, 25.5)
        XCTAssertNil(VPSUsage.parse("101 20 20"))
        XCTAssertNil(VPSUsage.parse("nan 20 20"))
        XCTAssertNil(VPSUsage.parse("20 20"))
    }
}
