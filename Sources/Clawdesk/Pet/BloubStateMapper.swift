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
/// | idle              | idle     | resting ball with the living gaze                |
/// | roam              | roam     | walking/bobbing desk movement                    |
/// | thinking          | thinking | the original thought-dot animation               |
/// | typing (working)  | play     | a distinct continuous working animation         |
/// | building          | building | continuous construction action                  |
/// | juggling (1)      | comet    | a single subagent racing by                      |
/// | juggling (2+)     | orbit    | multiSubagent -> orbit                           |
/// | sweeping          | sweeping | continuous compaction pass                      |
/// | carrying          | carrying | continuous preparing/holding action             |
/// | error / flail     | exclaim  | the "!"                                          |
/// | attention / happy | burst    | completed -> burst                               |
/// | notification      | notify   | the blue badge pop                               |
/// | yawning           | yawning  | full idle-sleep sequence                         |
/// | dozing            | dozing   | full idle-sleep sequence                         |
/// | collapsing        | collapsing | full idle-sleep sequence                       |
/// | sleeping          | sleeping | the sleeping dot                                |
/// | waking            | waking   | wake-up rings before the target state           |
/// | waking-from-doze  | waking-from-doze | short wake-up transition                  |
/// | dragging          | wide     | eyes wide while grabbed                          |
/// | reactDouble       | wink     | click reaction                                   |
/// | mini-*            | mini-*   | dedicated mini-mode motion and sleep states     |
public enum BloubStateMapper {
    public static func state(for petState: PetState) -> BloubState {
        switch petState {
        case .idle:
            return .idle
        case .roam:
            return .roam
        case .thinking:
            return .thinking
        case .typing:
            return .play
        case .building:
            return .building
        case .juggling:
            return .orbit
        case .sweeping:
            return .sweeping
        case .carrying:
            return .carrying
        case .error, .reactFlail:
            return .exclaim
        case .attention:
            return .burst
        case .notification:
            return .notify
        case .dizzy:
            return .dizzy
        case .yawning:
            return .yawning
        case .dozing:
            return .dozing
        case .collapsing:
            return .collapsing
        case .sleeping:
            return .sleeping
        case .waking:
            return .waking
        case .wakingFromDoze:
            return .wakingFromDoze
        case .dragging:
            return .wide
        case .reactDouble:
            return .wink
        case .miniIdle:
            return .miniIdle
        case .miniPeek:
            return .miniPeek
        case .miniAlert:
            return .miniAlert
        case .miniHappy:
            return .miniHappy
        case .miniWorking:
            return .miniWorking
        case .miniCrabwalk:
            return .miniCrabwalk
        case .miniEnter:
            return .miniEnter
        case .miniEnterSleep:
            return .miniEnterSleep
        case .miniSleep:
            return .miniSleep
        }
    }

    /// Subagent-aware refinement: a lone helper (or the two-session tier)
    /// reads as a comet, several as a full orbit.
    public static func state(for petState: PetState, subagentCount: Int) -> BloubState {
        guard petState == .juggling else { return state(for: petState) }
        return subagentCount >= 2 ? .orbit : .comet
    }
}
