import Foundation

/// Formats a byte count representing RAM using `.memory` count style (1024-based).
public func formatMemoryBytes(_ bytes: UInt64) -> String {
    let safeBytes = Int64(min(bytes, UInt64(Int64.max)))
    let formatter = ByteCountFormatter()
    formatter.countStyle = .memory
    formatter.allowedUnits = [.useAll]
    formatter.includesUnit = true
    return formatter.string(fromByteCount: safeBytes)
}

/// Formats a byte count representing disk storage using `.file` count style (1000-based decimal).
public func formatDiskBytes(_ bytes: UInt64) -> String {
    let safeBytes = Int64(min(bytes, UInt64(Int64.max)))
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useAll]
    formatter.includesUnit = true
    return formatter.string(fromByteCount: safeBytes)
}

/// Formats a percentage value (0...100) as an integer percentage string (e.g. "23%").
public func formatPercent(_ percent: Double) -> String {
    let clamped = max(0, min(100, percent))
    return "\(Int(clamped.rounded()))%"
}

/// Formats a percentage value (0...100) with one decimal place (e.g. "23.4%").
public func formatPercentPrecise(_ percent: Double) -> String {
    let clamped = max(0, min(100, percent))
    return String(format: "%.1f%%", clamped)
}

/// Formats a usage share as a whole percentage, but "<1%" for small non-zero values so that
/// only a true zero reads "0%" (e.g. "18%", "<1%", "0%").
public func formatUsagePercent(_ percent: Double) -> String {
    if percent > 0 && percent < 0.5 {
        return "<1%"
    }
    return formatPercent(percent)
}

/// Formats a process count with the right plural (e.g. "1 process", "14 processes").
public func formatProcessCount(_ count: Int) -> String {
    count == 1 ? "1 process" : "\(count.formatted()) processes"
}

/// Formats an averaging window: whole seconds from 1 s up (e.g. "10 s"), one decimal below (e.g. "0.5 s").
public func formatAveragingWindow(_ seconds: Double) -> String {
    let clamped = max(0, seconds)
    let tenths = (clamped * 10).rounded() / 10
    if tenths < 1 {
        return String(format: "%.1f s", tenths)
    }
    return "\(Int(clamped.rounded())) s"
}

/// Namespace providing convenient access to all metric formatters.
public enum MetricFormatting {
    public static func memoryBytes(_ bytes: UInt64) -> String { formatMemoryBytes(bytes) }
    public static func diskBytes(_ bytes: UInt64) -> String { formatDiskBytes(bytes) }
    public static func percent(_ percent: Double) -> String { formatPercent(percent) }
    public static func percentPrecise(_ percent: Double) -> String { formatPercentPrecise(percent) }
    public static func usagePercent(_ percent: Double) -> String { formatUsagePercent(percent) }
    public static func processCount(_ count: Int) -> String { formatProcessCount(count) }
    public static func averagingWindow(_ seconds: Double) -> String { formatAveragingWindow(seconds) }
}
