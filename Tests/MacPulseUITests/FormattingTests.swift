// Byte and percent formatting, including 1024 vs 1000 bases.
import XCTest
@testable import MacPulseUI

final class FormattingTests: XCTestCase {
    func testFormatPercentClampsAndRounds() {
        XCTAssertEqual(formatPercent(0), "0%")
        XCTAssertEqual(formatPercent(23.4), "23%")
        XCTAssertEqual(formatPercent(23.5), "24%")
        XCTAssertEqual(formatPercent(100), "100%")
        XCTAssertEqual(formatPercent(-8), "0%")
        XCTAssertEqual(formatPercent(140), "100%")
        XCTAssertEqual(MetricFormatting.percent(23.4), formatPercent(23.4))
    }

    func testFormatPercentPreciseClamps() {
        XCTAssertEqual(formatPercentPrecise(0), "0.0%")
        XCTAssertEqual(formatPercentPrecise(23.44), "23.4%")
        XCTAssertEqual(formatPercentPrecise(100), "100.0%")
        XCTAssertEqual(formatPercentPrecise(-3), "0.0%")
        XCTAssertEqual(formatPercentPrecise(128), "100.0%")
        XCTAssertEqual(MetricFormatting.percentPrecise(23.44), formatPercentPrecise(23.44))
    }

    func testMemoryUses1024AndDiskUses1000() {
        let oneGiB: UInt64 = 1024 * 1024 * 1024
        let memory = formatMemoryBytes(oneGiB)
        let disk = formatDiskBytes(oneGiB)
        XCTAssertEqual(memory, byteString(oneGiB, style: .memory))
        XCTAssertEqual(disk, byteString(oneGiB, style: .file))
        XCTAssertNotEqual(memory, disk, "1 GiB must not format the same in memory and file styles")
        XCTAssertEqual(MetricFormatting.memoryBytes(oneGiB), memory)
        XCTAssertEqual(MetricFormatting.diskBytes(oneGiB), disk)

        XCTAssertFalse(formatMemoryBytes(0).isEmpty)
        XCTAssertFalse(formatDiskBytes(0).isEmpty)
        XCTAssertFalse(formatMemoryBytes(.max).isEmpty)
        XCTAssertFalse(formatDiskBytes(.max).isEmpty)
    }

    func testProcessCountAndAveragingWindow() {
        XCTAssertEqual(formatProcessCount(1), "1 process")
        XCTAssertEqual(formatProcessCount(14), "14 processes")
        XCTAssertEqual(formatProcessCount(0), "0 processes")
        XCTAssertEqual(formatAveragingWindow(10), "10 s")
        XCTAssertEqual(formatAveragingWindow(1), "1 s")
        XCTAssertEqual(formatAveragingWindow(0.5), "0.5 s")
        XCTAssertEqual(formatAveragingWindow(0), "0.0 s")
        XCTAssertEqual(MetricFormatting.processCount(14), formatProcessCount(14))
        XCTAssertEqual(MetricFormatting.averagingWindow(0.5), formatAveragingWindow(0.5))
    }

    func testUsagePercentShowsSubOneOnlyForANonZeroSliver() {
        XCTAssertEqual(formatUsagePercent(0), "0%")
        XCTAssertEqual(formatUsagePercent(0.4), "<1%")
        XCTAssertEqual(formatUsagePercent(0.49), "<1%")
        XCTAssertEqual(formatUsagePercent(0.5), "1%")
        XCTAssertEqual(formatUsagePercent(18.2), "18%")
        XCTAssertEqual(formatUsagePercent(-3), "0%")
        XCTAssertEqual(MetricFormatting.usagePercent(0.4), "<1%")
    }
}

private func byteString(_ bytes: UInt64, style: ByteCountFormatter.CountStyle) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = style
    formatter.allowedUnits = [.useAll]
    formatter.includesUnit = true
    return formatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))))
}
