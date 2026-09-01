import Foundation

/// A provider-reported subscription window. Percentages use the upstream
/// convention: 0 is unused and 100 is exhausted.
public struct QuotaBucket: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let usedPercent: Int
    public let windowMinutes: Int?
    public let resetAt: Date?

    public init(id: String, usedPercent: Int, windowMinutes: Int? = nil, resetAt: Date? = nil) {
        self.id = id
        self.usedPercent = min(100, max(0, usedPercent))
        self.windowMinutes = windowMinutes
        self.resetAt = resetAt
    }

    public var displayWindow: String {
        guard let windowMinutes, windowMinutes > 0 else { return id }
        if windowMinutes % (24 * 60) == 0 { return "\(windowMinutes / (24 * 60))d" }
        if windowMinutes % 60 == 0 { return "\(windowMinutes / 60)h" }
        return "\(windowMinutes)m"
    }
}

public struct QuotaReport: Codable, Equatable, Sendable, Identifiable {
    public let providerID: String
    public let displayName: String
    public let buckets: [QuotaBucket]
    public let capturedAt: Date

    public var id: String { providerID }

    public init(providerID: String, displayName: String, buckets: [QuotaBucket], capturedAt: Date = .now) {
        self.providerID = providerID
        self.displayName = displayName
        self.buckets = buckets
        self.capturedAt = capturedAt
    }

    public var wireObject: [String: Any] {
        [
            "provider": providerID,
            "label": displayName,
            "capturedAt": capturedAt.timeIntervalSince1970 * 1000,
            "buckets": buckets.map { bucket in
                var object: [String: Any] = [
                    "id": bucket.id,
                    "usedPercent": bucket.usedPercent,
                    "window": bucket.displayWindow
                ]
                if let windowMinutes = bucket.windowMinutes { object["windowMinutes"] = windowMinutes }
                if let resetAt = bucket.resetAt { object["resetAt"] = resetAt.timeIntervalSince1970 * 1000 }
                return object
            }
        ]
    }
}

public final class QuotaStore {
    private struct PersistedState: Codable {
        let version: Int
        let reports: [QuotaReport]
    }

    private var reportsByProvider: [String: QuotaReport] = [:]
    private let persistenceURL: URL?
    private let fileManager: FileManager

    private static let defaultPersistenceURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".clawd/account-quota.json")
    private static let maximumPersistedBytes = 1_000_000
    private static let maximumPersistedReports = 64

    /// The normal store survives relaunches so a recently reported balance is
    /// available before the next statusline or Codex rollout event arrives.
    /// Tests and embedders can pass `nil` for an in-memory store.
    public init() {
        self.persistenceURL = Self.defaultPersistenceURL
        self.fileManager = .default
        load()
    }

    public init(persistenceURL: URL?, fileManager: FileManager = .default) {
        self.persistenceURL = persistenceURL
        self.fileManager = fileManager
        load()
    }

    public var reports: [QuotaReport] {
        reportsByProvider.values.sorted { lhs, rhs in
            if lhs.capturedAt == rhs.capturedAt { return lhs.providerID < rhs.providerID }
            return lhs.capturedAt > rhs.capturedAt
        }
    }

    @discardableResult
    public func apply(_ report: QuotaReport) -> [QuotaReport] {
        if let existing = reportsByProvider[report.providerID], existing.capturedAt > report.capturedAt {
            return reports
        }
        reportsByProvider[report.providerID] = report
        persist()
        return reports
    }

    public func removeAll() {
        reportsByProvider.removeAll()
        persist()
    }

    private func load() {
        guard let persistenceURL,
              let attributes = try? fileManager.attributesOfItem(atPath: persistenceURL.path),
              let byteCount = attributes[.size] as? NSNumber,
              byteCount.intValue <= Self.maximumPersistedBytes,
              let data = try? Data(contentsOf: persistenceURL) else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded: [QuotaReport]?
        if let state = try? decoder.decode(PersistedState.self, from: data), state.version == 1 {
            loaded = state.reports
        } else {
            loaded = try? decoder.decode([QuotaReport].self, from: data)
        }
        for report in (loaded ?? []).prefix(Self.maximumPersistedReports) {
            if let existing = reportsByProvider[report.providerID], existing.capturedAt >= report.capturedAt {
                continue
            }
            reportsByProvider[report.providerID] = report
        }
    }

    private func persist() {
        guard let persistenceURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let state = PersistedState(version: 1, reports: reports)
        guard let data = try? encoder.encode(state) else { return }
        do {
            try fileManager.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: persistenceURL, options: [.atomic])
        } catch {
            // Quota is advisory. A read-only home or a transient disk error
            // must never interfere with lifecycle events or the HUD.
        }
    }
}

/// Agent-specific quota decoding lives behind this adapter. The event server
/// only extracts the untrusted rate-limit object and never decides which
/// provider parser should consume it.
public protocol AgentQuotaAdapter {
    func quotaReport(
        agentID: String,
        rateLimits: [String: Any],
        capturedAt: Date,
        now: Date
    ) -> QuotaReport?
}

public struct DefaultAgentQuotaAdapter: AgentQuotaAdapter {
    public init() {}

    public func quotaReport(
        agentID: String,
        rateLimits: [String: Any],
        capturedAt: Date,
        now: Date
    ) -> QuotaReport? {
        let normalized = agentID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("claude") {
            return QuotaReportParser.claude(rateLimits: rateLimits, capturedAt: capturedAt)
        }
        if normalized.contains("codex") {
            return QuotaReportParser.codex(rateLimits: rateLimits, capturedAt: capturedAt, now: now)
        }
        return nil
    }
}

/// Converts the small JSON fragments emitted by Claude statusline and Codex
/// rollout records into one native representation. The parser is deliberately
/// independent from the UI so an upstream field rename only changes this seam.
public enum QuotaReportParser {
    public static func claude(rateLimits: [String: Any], capturedAt: Date = .now) -> QuotaReport? {
        let definitions: [(String, String, Int)] = [
            ("five_hour", "fiveHour", 5 * 60),
            ("seven_day", "weekly", 7 * 24 * 60)
        ]
        let buckets: [QuotaBucket] = definitions.compactMap { definition in
            let (sourceKey, id, fallbackWindow) = definition
            guard let source = rateLimits[sourceKey] as? [String: Any],
                  let used = number(source["used_percentage"]) else { return nil }
            return QuotaBucket(
                id: id,
                usedPercent: Int(used.rounded()),
                windowMinutes: fallbackWindow,
                resetAt: absoluteDate(seconds: number(source["resets_at"]))
            )
        }
        guard !buckets.isEmpty else { return nil }
        return QuotaReport(providerID: "claude", displayName: "Claude", buckets: buckets, capturedAt: capturedAt)
    }

    public static func codex(
        rateLimits: [String: Any],
        capturedAt: Date = .now,
        now: Date = .now,
        providerHint: String? = nil
    ) -> QuotaReport? {
        let rawLimitID = (rateLimits["limit_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let providerID: String
        let displayName: String
        switch rawLimitID {
        case "codex_bengalfox":
            providerID = "codex-spark"
            displayName = "Codex Spark"
        case "codex", nil, "":
            if providerHint == "codex-spark" {
                providerID = "codex-spark"
                displayName = "Codex Spark"
            } else {
                providerID = "codex"
                displayName = "Codex"
            }
        default:
            return nil
        }

        let sources = ["primary", "secondary"].compactMap { key -> (String, [String: Any])? in
            guard let value = rateLimits[key] as? [String: Any] else { return nil }
            return (key, value)
        }
        var buckets: [QuotaBucket] = []
        for (key, source) in sources {
            guard let used = number(source["used_percent"]) else { continue }
            let window = number(source["window_minutes"]).map { Int($0.rounded()) }
            let id: String
            if let window, window >= 24 * 60 {
                id = buckets.contains(where: { $0.id == "weekly" }) ? "fiveHour" : "weekly"
            } else if let window {
                id = buckets.contains(where: { $0.id == "fiveHour" }) ? "weekly" : "fiveHour"
                _ = window
            } else {
                id = key == "primary" && !buckets.contains(where: { $0.id == "fiveHour" }) ? "fiveHour" : "weekly"
            }
            let resetAt = absoluteDate(seconds: number(source["resets_at"]))
                ?? relativeDate(seconds: number(source["resets_in_seconds"]), now: now)
            buckets.append(QuotaBucket(
                id: id,
                usedPercent: Int(used.rounded()),
                windowMinutes: window,
                resetAt: resetAt
            ))
        }
        guard !buckets.isEmpty else { return nil }
        return QuotaReport(providerID: providerID, displayName: displayName, buckets: buckets, capturedAt: capturedAt)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func absoluteDate(seconds: Double?) -> Date? {
        guard let seconds, seconds.isFinite, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func relativeDate(seconds: Double?, now: Date) -> Date? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return now.addingTimeInterval(seconds)
    }
}
