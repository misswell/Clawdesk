import Foundation

/// The compact visual vocabulary used by the native Session HUD.
///
/// Keeping this policy outside AppKit makes the chip deterministic, cheap to
/// render, and easy to extend when another agent reports context telemetry.
public enum ContextUsageSeverity: String, Equatable, Sendable {
    case neutral
    case warm
    case hot
}

public struct ContextUsagePresentation: Equatable, Sendable {
    public let label: String
    public let severity: ContextUsageSeverity

    public init(label: String, severity: ContextUsageSeverity) {
        self.label = label
        self.severity = severity
    }
}

public enum ContextUsageFormatter {
    public static func presentation(for usage: ContextUsage?) -> ContextUsagePresentation? {
        guard let usage, usage.used > 0 else { return nil }

        if let percent = usage.percent {
            let normalized = min(100, max(0, percent))
            let severity: ContextUsageSeverity
            if normalized >= 90 {
                severity = .hot
            } else if normalized >= 75 {
                severity = .warm
            } else {
                severity = .neutral
            }
            return ContextUsagePresentation(label: "\(normalized)%", severity: severity)
        }

        return ContextUsagePresentation(
            label: tokenLabel(usage.used),
            severity: .neutral
        )
    }

    public static func tokenLabel(_ value: Double) -> String {
        let normalized = max(0, value.isFinite ? value : 0)
        if normalized >= 1_000_000 {
            return compact(normalized / 1_000_000, decimals: normalized >= 10_000_000 ? 0 : 1) + "m"
        }
        if normalized >= 1_000 {
            return compact(normalized / 1_000, decimals: normalized >= 10_000 ? 0 : 1) + "k"
        }
        return String(Int(normalized.rounded()))
    }

    private static func compact(_ value: Double, decimals: Int) -> String {
        guard decimals > 0 else { return String(Int(value.rounded())) }
        let rounded = (value * 10).rounded() / 10
        if rounded.rounded() == rounded {
            return String(Int(rounded))
        }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), rounded)
    }
}
