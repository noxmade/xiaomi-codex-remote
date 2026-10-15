import Foundation
import Observation

/// GUI-owned runtime. Public methods and transport callbacks run on main.
@Observable
final class NativeCodexBridge {
    enum State: Equatable { case stopped, starting, running, failed(String) }
    private(set) var state: State = .stopped
    private(set) var shimConnected = false
    let agentSwitch: AgentSwitchState
    let socketPath: String
    var onLogLine: ((String) -> Void)?
    var onShimConnectionChange: ((Bool) -> Void)?
    @ObservationIgnored private let server: CodexSocketServer
    @ObservationIgnored private let emulator = CodexEmulator()
    @ObservationIgnored private lazy var router = XiaomiInputRouter(emulator: emulator, agentSwitch: agentSwitch)
    @ObservationIgnored private var reassembler = CodexFrameReassembler()

    init(socketPath: String = ChatGPTShimConfiguration.socketPath,
         agentSwitch: AgentSwitchState = AgentSwitchState()) {
        self.agentSwitch = agentSwitch
        self.socketPath = socketPath
        server = CodexSocketServer(path: socketPath)
        server.onFrame = { [weak self] frame in self?.receive(frame) }
        server.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            self.shimConnected = connected
            self.reassembler = CodexFrameReassembler()
            if !connected { self.router.releaseAll() }
            self.onShimConnectionChange?(connected)
            self.onLogLine?(connected ? "Shim 已连接" : "Shim 已断开")
        }
        server.onError = { [weak self] error in
            self?.releaseHeldKeys()
            self?.onLogLine?("通信错误: \(error)")
        }
        emulator.onSend = { [weak self] message in
            guard let self else { return }
            do {
                let line = try message.encodedLine()
                for frame in CodexFrameEncoder.encode(line) { self.server.write(frame) }
                self.onLogLine?(line.trimmingCharacters(in: .newlines))
            } catch { self.onLogLine?("编码错误: \(error.localizedDescription)") }
        }
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state != .running else { return }
        state = .starting
        reassembler = CodexFrameReassembler()
        do {
            try server.start()
            state = .running
            onLogLine?("原生 Swift 协议引擎已启动")
        } catch {
            state = .failed(error.localizedDescription)
            onLogLine?("启动失败: \(error.localizedDescription)；请检查是否已有桥接服务占用 socket")
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(.main))
        router.releaseAll()
        server.stop()
        shimConnected = false
        reassembler = CodexFrameReassembler()
        state = .stopped
    }

    func restart() { stop(); start() }
    func releaseHeldKeys() { router.releaseAll() }
    func applyKeyMapping(_ mapping: [String: XiaomiBinding?]) {
        dispatchPrecondition(condition: .onQueue(.main))
        router.releaseAll()
        router = XiaomiInputRouter(emulator: emulator, mapping: mapping, agentSwitch: agentSwitch)
    }
    func setAgentSwitchMode(_ mode: AgentSwitchMode) {
        dispatchPrecondition(condition: .onQueue(.main))
        router.releaseAll()
        agentSwitch.mode = mode
    }

    @discardableResult
    func selectAgentSlot(_ slot: Int) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state == .running, shimConnected, (0..<6).contains(slot) else { return false }
        router.releaseAll()
        let key = CodexProtocol.Key.agents[slot]
        emulator.sendKey(key, action: CodexProtocol.Action.press, agent: slot)
        emulator.sendKey(key, action: CodexProtocol.Action.release, agent: slot)
        agentSwitch.record(slot)
        return true
    }

    func handle(key: String, action: XiaomiKeyAction) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state == .running, shimConnected else { return }
        router.handle(.init(key: key, action: action))
    }

    private func receive(_ frame: Data) {
        for message in reassembler.push(frame) where message.channel == CodexChannel.rpc.rawValue {
            do { emulator.handle(try CodexJSON.parse(message.message)) }
            catch { onLogLine?("忽略无效 RPC: \(error.localizedDescription)") }
        }
    }
}
