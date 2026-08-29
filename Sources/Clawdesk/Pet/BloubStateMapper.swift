import Foundation

/// The single seam between Clawdesk's agent semantics and the bloub visual
/// language.
///
/// The agent runtime speaks `PetState` and must never reference `BloubState`
/// directly: an adapter that set `orbit` would weld agent behavior to pet
/// appearance. Swap the pet by replacing this mapper — `PetState` does not
/// change.
///
/// First-version mapping (adjustable after visual review, per the upstream
/// pet architecture note):
///
/// | PetState          | Bloub    | Because                                          |
/// | ----------------- | -------- | ------------------------------------------------ |
/// | idle / miniIdle   | idle     | resting ball with the living gaze                |
/// | thinking          | thinking | the three-dot thought pulse                      |
/// | typing (working)  | orbit    | working -> orbit per the mapping table           |
/// | building          | hexagon  | building -> hexagon                              |
/// | juggling (1)      | comet    | a single subagent racing by                      |
/// | juggling (2+)     | orbit    | multiSubagent -> orbit                           |
/// | sweeping          | comet    | compaction pass, a trail around a shrinking core |
/// | carrying          | egg      | preparing: potential held quietly                |
/// | error / flail     | exclaim  | the "!"                                          |
/// | attention / happy | burst    | completed -> burst                               |
/// | notification      | notify   | the blue badge pop                               |
/// | yawn..sleeping    | sleep    | the sleeping dot (Clawdesk keeps its sequence)   |
/// | waking            | swirl    | wake-up rings before the target state            |
/// | dragging          | wide     | eyes wide while grabbed                          |
/// | reactDouble       | wink     | click reaction                                   |
public enum BloubStateMapper {
    public static func state(for petState: PetState) -> BloubState {
        switch petState {
        case .idle, .miniIdle, .miniPeek:
            return .idle
        case .thinking:
            return .thinking
        case .typing:
            return .orbit
        case .building:
            return .hexagon
        case .juggling:
            return .orbit
        case .sweeping:
            return .comet
        case .carrying:
            return .egg
        case .error, .reactFlail:
            return .exclaim
        case .attention, .miniHappy:
            return .burst
        case .notification, .miniAlert:
            return .notify
        case .yawning, .dozing, .collapsing, .sleeping:
            return .sleep
        case .waking, .wakingFromDoze:
            return .swirl
        case .dragging:
            return .wide
        case .reactDouble:
            return .wink
        }
    }

    /// Subagent-aware refinement: a lone helper (or the two-session tier)
    /// reads as a comet, several as a full orbit.
    public static func state(for petState: PetState, subagentCount: Int) -> BloubState {
        guard petState == .juggling else { return state(for: petState) }
        return subagentCount >= 2 ? .orbit : .comet
    }
}
