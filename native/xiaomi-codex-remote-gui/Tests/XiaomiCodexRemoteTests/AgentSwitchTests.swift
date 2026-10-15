import XCTest
@testable import XiaomiCodexRemote

final class AgentSwitchTests: XCTestCase {
    func testEveryCycleBoundaryAndHeldReleaseTarget() {
        for slot in 0..<6 {
            for key in ["home", "menu"] {
                let state = AgentSwitchState(mode: .cycle, slot: slot)
                let emulator = CodexEmulator()
                var messages: [CodexJSON] = []
                emulator.onSend = { messages.append($0) }
                let router = XiaomiInputRouter(emulator: emulator, agentSwitch: state)
                let target = (slot + (key == "home" ? 5 : 1)) % 6
                XCTAssertTrue(router.handle(.init(key: key, action: .press)))
                XCTAssertFalse(router.handle(.init(key: key, action: .press)))
                XCTAssertFalse(router.handle(.init(key: key, action: .repeat)))
                XCTAssertEqual(state.slot, target)
                state.record((target + 1) % 6)
                XCTAssertTrue(router.handle(.init(key: key, action: .release)))
                XCTAssertEqual(messages.count, 2)
                for (index, message) in messages.enumerated() {
                    XCTAssertEqual(message["p"]?["k"], .string("AG0\(target)"))
                    XCTAssertEqual(message["p"]?["ag"], .number(Double(target)))
                    XCTAssertEqual(message["p"]?["act"], .number(index == 0 ? 1 : 0))
                }
            }
        }
    }

    func testModeSwitchReleasesAndPreservesCustomMappingAndCursor() {
        let state = AgentSwitchState(mode: .cycle, slot: 5)
        let bridge = NativeCodexBridge(agentSwitch: state)
        let emulator = CodexEmulator()
        var messages: [CodexJSON] = []
        emulator.onSend = { messages.append($0) }
        let mapping = try! XiaomiKeyMapping.make(overrides: [
            "home": .init(kind: .key, keycode: "AG03", agent: nil, angle: nil)
        ])
        let router = XiaomiInputRouter(emulator: emulator, mapping: mapping, agentSwitch: state)
        router.handle(.init(key: "menu", action: .press))
        router.releaseAll()
        bridge.setAgentSwitchMode(.fixed)
        XCTAssertEqual(messages.last?["p"]?["act"], .number(0))
        XCTAssertEqual(state.slot, 0)
        router.handle(.init(key: "home", action: .press))
        XCTAssertEqual(state.slot, 3)
        XCTAssertEqual(messages.last?["p"]?["k"], .string("AG03"))
        router.releaseAll()
        bridge.setAgentSwitchMode(.cycle)
        bridge.applyKeyMapping(mapping)
        XCTAssertEqual(state.slot, 3)
        router.handle(.init(key: "menu", action: .press))
        XCTAssertEqual(state.slot, 4)
    }

    func testPreferencesDefaultsValidationAndRestore() {
        let name = "AgentSwitchTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppPreferences.agentSwitchMode(in: defaults), .fixed)
        XCTAssertEqual(AppPreferences.lastRequestedAgentSlot(in: defaults), 0)
        defaults.set("cycle", forKey: AppPreferences.agentSwitchModeKey)
        defaults.set(5, forKey: AppPreferences.lastRequestedAgentSlotKey)
        XCTAssertEqual(AppPreferences.agentSwitchMode(in: defaults), .cycle)
        XCTAssertEqual(AppPreferences.lastRequestedAgentSlot(in: defaults), 5)
        defaults.set("unknown", forKey: AppPreferences.agentSwitchModeKey)
        for value in [-1, 6] {
            defaults.set(value, forKey: AppPreferences.lastRequestedAgentSlotKey)
            XCTAssertEqual(AppPreferences.lastRequestedAgentSlot(in: defaults), 0)
        }
        XCTAssertEqual(AppPreferences.agentSwitchMode(in: defaults), .fixed)
    }

    func testDisconnectedInputDoesNotAdvanceOrReposition() {
        let state = AgentSwitchState(mode: .cycle, slot: 3)
        let bridge = NativeCodexBridge(agentSwitch: state)
        bridge.handle(key: "menu", action: .press)
        XCTAssertFalse(bridge.selectAgentSlot(4))
        bridge.releaseHeldKeys()
        bridge.stop()
        XCTAssertEqual(state.slot, 3)
    }

    func testBridgeModeSwitchAndReconnect() throws {
        let state = AgentSwitchState(mode: .cycle, slot: 5)
        let bridge = NativeCodexBridge(socketPath: "/tmp/ac-\(UUID()).sock", agentSwitch: state)
        bridge.start()
        defer { bridge.stop() }
        let first = try UnixTestClient(path: bridge.socketPath)
        eventually { bridge.shimConnected }
        var frames = CodexFrameReassembler()
        func read(_ client: UnixTestClient) throws -> CodexJSON {
            try CodexJSON.parse(XCTUnwrap(frames.push(client.read(count: 64)).first).message)
        }
        bridge.handle(key: "menu", action: .press)
        XCTAssertEqual(try read(first)["p"]?["k"], .string("AG00"))
        bridge.setAgentSwitchMode(.fixed)
        XCTAssertEqual(try read(first)["p"]?["act"], .number(0))
        bridge.handle(key: "menu", action: .release)
        bridge.handle(key: "menu", action: .press)
        XCTAssertEqual(try read(first)["p"]?["k"], .string("AG01"))
        first.close()
        eventually { !bridge.shimConnected }
        bridge.handle(key: "menu", action: .press)
        XCTAssertEqual(state.slot, 1)
        bridge.setAgentSwitchMode(.cycle)
        let next = try UnixTestClient(path: bridge.socketPath)
        eventually { bridge.shimConnected }
        XCTAssertEqual(state.slot, 1)
        bridge.handle(key: "menu", action: .press)
        XCTAssertEqual(try read(next)["p"]?["k"], .string("AG02"))
        XCTAssertTrue(bridge.selectAgentSlot(5))
        XCTAssertEqual(try read(next)["p"]?["act"], .number(0))
        XCTAssertEqual(try read(next)["p"]?["k"], .string("AG05"))
        XCTAssertEqual(try read(next)["p"]?["act"], .number(0))
        XCTAssertEqual(state.slot, 5)
    }
}
