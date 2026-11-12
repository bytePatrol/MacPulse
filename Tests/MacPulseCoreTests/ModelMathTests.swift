// Acceptance tests for the shared metric math.
import XCTest
@testable import MacPulseCore

final class ModelMathTests: XCTestCase {
    func testMemoryBytesAndPercentEdgeCases() {
        let cases: [(total: UInt64, used: UInt64, available: UInt64, percent: Double)] = [
            (0, 0, 0, 0),
            (0, 50, 0, 0),
            (1_000, 0, 1_000, 0),
            (1_000, 250, 750, 25),
            (1_000, 1_000, 0, 100),
            (1_000, 1_500, 0, 100),
            (3, 1, 2, 100.0 / 3.0),
        ]

        for item in cases {
            let memory = MemoryUsage(totalBytes: item.total, usedBytes: item.used)
            XCTAssertEqual(
                memory.availableBytes,
                item.available,
                "available for total \(item.total) used \(item.used)"
            )
            XCTAssertEqual(
                memory.usedPercent,
                item.percent,
                accuracy: 0.000_000_1,
                "percent for total \(item.total) used \(item.used)"
            )
            XCTAssertGreaterThanOrEqual(memory.usedPercent, 0)
            XCTAssertLessThanOrEqual(memory.usedPercent, 100)
        }
    }

    func testDiskBytesAndPercentEdgeCases() {
        let cases: [(total: UInt64, available: UInt64, used: UInt64, percent: Double)] = [
            (0, 0, 0, 0),
            (0, 40, 0, 0),
            (1_000, 0, 1_000, 100),
            (1_000, 250, 750, 75),
            (1_000, 1_000, 0, 0),
            (1_000, 1_500, 0, 0),
            (8, 2, 6, 75),
        ]

        for item in cases {
            let disk = DiskUsage(totalBytes: item.total, availableBytes: item.available)
            XCTAssertEqual(
                disk.usedBytes,
                item.used,
                "used for total \(item.total) available \(item.available)"
            )
            XCTAssertEqual(
                disk.usedPercent,
                item.percent,
                accuracy: 0.000_000_1,
                "percent for total \(item.total) available \(item.available)"
            )
            XCTAssertGreaterThanOrEqual(disk.usedPercent, 0)
            XCTAssertLessThanOrEqual(disk.usedPercent, 100)
        }
    }

    func testMetricSampleIdentityIsTimestamp() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let sample = MetricSample(timestamp: timestamp, value: 42.5)
        XCTAssertEqual(sample.id, timestamp)
        XCTAssertEqual(sample.value, 42.5)
    }
}
