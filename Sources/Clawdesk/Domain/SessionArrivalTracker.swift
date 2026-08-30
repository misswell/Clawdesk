import Foundation

/// Detects genuinely new sessions from the stream of session snapshots.
///
/// Clawdesk Behavior: a fresh session earns a one-shot wink (architecture §8
/// lists "Session Start / Agent Connect" among the micro interactions). The
/// first batch after launch only seeds the tracker — waking up mid-work with
/// several live sessions should not make the pet celebrate its own boot.
public struct SessionArrivalTracker: Equatable, Sendable {
    private var knownIDs: Set<String> = []
    private var seeded = false

    public init() {}

    /// Returns the IDs that were not known before this call. The very first
    /// non-empty batch seeds the tracker and reports nothing.
    public mutating func arrivals(in sessions: [SessionSnapshot]) -> [String] {
        let fresh = sessions
            .map(\.id)
            .filter { !knownIDs.contains($0) }
        let isFirstBatch = !seeded
        if !sessions.isEmpty {
            seeded = true
        }
        knownIDs = Set(sessions.map(\.id))
        if isFirstBatch {
            return []
        }
        return fresh
    }
}
