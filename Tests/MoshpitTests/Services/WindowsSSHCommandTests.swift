import XCTest
@testable import Moshpit
final class WindowsSSHCommandTests: XCTestCase {
    func testEncodingMatchesWindowsPowerShell() throws {
        let command = WindowsSSHCommand.encode("Write-Output 'Tiếng Việt'")
        XCTAssertTrue(WindowsSSHCommand.isEncoded(command))
        let payload = try XCTUnwrap(command.split(separator: ":").last)
        let decoded = try XCTUnwrap(Data(base64Encoded: String(payload)))
        let script = try XCTUnwrap(String(data: decoded, encoding: .utf16LittleEndian))
        XCTAssertTrue(script.contains("Write-Output 'Tiếng Việt'"))
        XCTAssertTrue(script.contains("[Console]::OutputEncoding"))
        XCTAssertFalse(WindowsSSHCommand.isEncoded("echo hello"))
    }
}
