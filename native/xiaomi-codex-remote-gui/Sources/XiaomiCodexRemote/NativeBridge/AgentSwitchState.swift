import Foundation
import Observation

enum AgentSwitchMode: String {
    case fixed
    case cycle
}

/// Last requested slot, not an acknowledgement of the host's selection.
@Observable
final class AgentSwitchState {
    var mode: AgentSwitchMode
    private(set) var slot: Int
    var onSlotChange: ((Int) -> Void)?

    init(mode: AgentSwitchMode = .fixed, slot: Int = 0) {
        self.mode = mode
        self.slot = (0..<6).contains(slot) ? slot : 0
    }

    func record(_ slot: Int) {
        guard (0..<6).contains(slot) else { return }
        self.slot = slot
        onSlotChange?(slot)
    }

    func binding(for key: String) -> XiaomiBinding? {
        guard mode == .cycle, key == "home" || key == "menu" else { return nil }
        let target = (slot + (key == "home" ? 5 : 1)) % 6
        return .init(kind: .key, keycode: CodexProtocol.Key.agents[target], agent: target, angle: nil)
    }
}
