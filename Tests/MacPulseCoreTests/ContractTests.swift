import XCTest
@testable import MacPulseCore

final class ContractTests: XCTestCase {
    func testVersionIsOnePointZero() {
        XCTAssertEqual(MacPulseInfo.version, "1.0")
    }
}
