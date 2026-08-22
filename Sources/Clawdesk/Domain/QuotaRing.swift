import CoreGraphics
import Foundation

/// A provider's quota coin: an outer ring for the shorter/rolling window and
/// an optional inner ring for the longer (weekly) window, mirroring the
/// upstream "Orbit" quota ring semantics.
public struct QuotaCoin: Equatable, Sendable {
    public let providerID: String
    public let label: String
    public let outerPercent: Int
    public let innerPercent: Int?

    public init(providerID: String, label: String, outerPercent: Int, innerPercent: Int?) {
        self.providerID = providerID
        self.label = label
        self.outerPercent = outerPercent
        self.innerPercent = innerPercent
    }
}

/// Pure geometry for the pet-attached quota ring, translated from the
/// upstream `quota-ring-geometry.js`. The caller owns window sizing and
/// positioning; this module decides which coins draw and their footprint.
public enum QuotaRingGeometry {
    public static let coinSize: CGFloat = 30
    public static let coinGap: CGFloat = 8
    public static let maxCoins = 4
    public static let petGap: CGFloat = 8
    public static let edgeMargin: CGFloat = 8
    public static let readoutWidth: CGFloat = 44
    public static let overflowHeight: CGFloat = 20

    public static func coin(for report: QuotaReport) -> QuotaCoin? {
        let ordered = report.buckets.sorted { lhs, rhs in
            let left = lhs.windowMinutes ?? Int.max
            let right = rhs.windowMinutes ?? Int.max
            if left == right { return lhs.id < rhs.id }
            return left < right
        }
        guard let outer = ordered.first else { return nil }
        let inner = ordered.count > 1 ? ordered[1] : nil
        return QuotaCoin(
            providerID: report.providerID,
            label: report.displayName,
            outerPercent: outer.usedPercent,
            innerPercent: inner.map { $0.usedPercent }
        )
    }

    public static func coins(
        from reports: [QuotaReport],
        show: Bool,
        hiddenProviders: Set<String> = []
    ) -> (coins: [QuotaCoin], overflow: Int) {
        guard show else { return ([], 0) }
        var coins: [QuotaCoin] = []
        var overflow = 0
        for report in reports where !hiddenProviders.contains(report.providerID) {
            guard let coin = coin(for: report) else { continue }
            if coins.count < maxCoins {
                coins.append(coin)
            } else {
                overflow += 1
            }
        }
        return (coins, overflow)
    }

    public static func clusterSize(coinCount: Int, overflow: Int) -> CGSize {
        var height = CGFloat(coinCount) * coinSize + CGFloat(max(0, coinCount - 1)) * coinGap
        if overflow > 0 { height += overflowHeight + 8 }
        return CGSize(width: coinSize + readoutWidth + 10, height: max(0, height))
    }

    public static func coinRect(index: Int, size: CGSize) -> CGRect {
        let bottomY = size.height - CGFloat(index + 1) * coinSize - CGFloat(index) * coinGap
        return CGRect(x: 0, y: bottomY, width: coinSize, height: coinSize)
    }
}
