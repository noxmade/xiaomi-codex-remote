import Foundation

enum XiaomiKeyAction: String, Codable {
    case press
    case release
    case `repeat`
}

struct XiaomiKeyEvent: Equatable {
    let key: String
    let action: XiaomiKeyAction
}

final class XiaomiInputRouter {
    private let emulator: CodexEmulator
    private let mapping: [String: XiaomiBinding?]
    private let agentSwitch: AgentSwitchState
    private var pressed: [String: XiaomiBinding] = [:]

    init(emulator: CodexEmulator, mapping: [String: XiaomiBinding?] = XiaomiKeyMapping.defaults,
         agentSwitch: AgentSwitchState = AgentSwitchState()) {
        self.emulator = emulator
        self.mapping = mapping
        self.agentSwitch = agentSwitch
    }

    @discardableResult
    func handle(_ event: XiaomiKeyEvent) -> Bool {
        // Releases use the target captured at press, even if the cursor has moved.
        guard let binding = pressed[event.key] ?? agentSwitch.binding(for: event.key) ?? mapping[event.key].flatMap({ $0 }) else { return false }
        let held = pressed[event.key] != nil

        switch event.action {
        case .release:
            guard held else { return false }
            pressed.removeValue(forKey: event.key)
            if binding.kind == .joystick {
                emulator.sendJoystick(angle: binding.angle ?? 0.0, distance: 0.0)
            } else if binding.kind == .key {
                emulator.sendKey(binding.keycode ?? "", action: CodexProtocol.Action.release, agent: binding.agent)
            }
        case .press:
            guard !held else { return false }
            pressed[event.key] = binding
            if binding.kind == .joystick {
                emulator.sendJoystick(angle: binding.angle ?? 0.0, distance: 1.0)
            } else {
                let action = binding.kind == .rotate ? CodexProtocol.Action.rotate : CodexProtocol.Action.press
                emulator.sendKey(binding.keycode ?? "", action: action, agent: binding.agent)
                if let agent = binding.agent { agentSwitch.record(agent) }
            }
        case .repeat:
            guard held else { return false }
            if binding.kind == .joystick {
                emulator.sendJoystick(angle: binding.angle ?? 0.0, distance: 1.0)
            } else if binding.kind == .rotate {
                emulator.sendKey(binding.keycode ?? "", action: CodexProtocol.Action.rotate, agent: binding.agent)
            } else {
                return false
            }
        }

        return true
    }

    func releaseAll() {
        for binding in pressed.values {
            if binding.kind == .joystick {
                emulator.sendJoystick(angle: binding.angle ?? 0.0, distance: 0.0)
            } else if binding.kind == .key {
                emulator.sendKey(binding.keycode ?? "", action: CodexProtocol.Action.release, agent: binding.agent)
            }
        }
        pressed.removeAll()
    }
}
