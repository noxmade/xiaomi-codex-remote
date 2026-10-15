import AppKit
import Foundation

enum PowerLaunchDecision: Equatable {
    case ignore, restoreWindow, reopenAndWait, confirmRestart, prepareAndLaunch, unavailable

    static func make(remoteRunning: Bool, connected: Bool,
                     compatibility: ChatGPTCompatibilityState, busy: Bool,
                     reconnectTimedOut: Bool) -> Self {
        if busy { return .ignore }
        if remoteRunning && connected { return .restoreWindow }
        if compatibility == .sourceMissing {
            return remoteRunning ? .reopenAndWait : .unavailable
        }
        if remoteRunning {
            if case .ready = compatibility {
                return reconnectTimedOut ? .confirmRestart : .reopenAndWait
            }
            return .confirmRestart
        }
        return .prepareAndLaunch
    }
}

enum RemoteLaunchPreparation {
    static func run(stopHost: () throws -> Void,
                    inspect: () -> ChatGPTCompatibilityState,
                    prepare: () throws -> Void) throws {
        if case .sourceMissing = inspect() {
            throw ChatGPTCompatibilityError.invalidSource("请先安装官方 ChatGPT，再使用遥控版。")
        }
        try stopHost()
        if case .ready = inspect() { return }
        try prepare()
        guard case .ready = inspect() else {
            throw ChatGPTCompatibilityError.verificationFailed("遥控支持尚未就绪，请查看设置。")
        }
    }
}

/// Owns the user-visible compatibility state and launches the managed ChatGPT
/// copy. Preparation and launch are always initiated by an explicit user action.
@Observable
final class ChatGPTLauncher {
    private(set) var compatibilityState: ChatGPTCompatibilityState = .checking
    private(set) var launchState: ChatGPTLaunchState = .idle
    private(set) var powerLaunchInProgress = false
    private(set) var powerActionDescription = ""
    private(set) var reconnectTimedOut = false
    private var connectionAttempt = UUID()
    private var restoreAfterConnect = false
    private var windowRequest = UUID()
    var onWindowError: ((String) -> Void)?
    private let runningRemoteOverride: (() -> Bool)?
    private let reopenRemoteOverride: ((URL, @escaping (Result<Void, Error>) -> Void) -> Void)?
    private let connectionTimeout: TimeInterval
    private let confirmRestartOverride: (() -> Bool)?
    let compatibilityManager: ChatGPTCompatibilityManager

    var chatGPTPath: String? {
        if case .ready = compatibilityState { return compatibilityManager.patchedAppURL.path }
        return nil
    }

    init(
        resourceURL: URL? = Bundle.main.resourceURL,
        officialAppURL: URL? = nil,
        patchedAppURL: URL? = nil,
        compatibilityManager: ChatGPTCompatibilityManager? = nil,
        runningRemote: (() -> Bool)? = nil,
        reopenRemote: ((URL, @escaping (Result<Void, Error>) -> Void) -> Void)? = nil,
        connectionTimeout: TimeInterval = 10,
        confirmRestart: (() -> Bool)? = nil
    ) {
        self.runningRemoteOverride = runningRemote
        self.reopenRemoteOverride = reopenRemote
        self.connectionTimeout = connectionTimeout
        self.confirmRestartOverride = confirmRestart
        self.compatibilityManager = compatibilityManager ?? ChatGPTCompatibilityManager(
            resourceURL: resourceURL,
            officialAppURL: officialAppURL,
            patchedAppURL: patchedAppURL
        )
        compatibilityState = self.compatibilityManager.inspect()
    }

    func resolveShimPath(debugProjectRoot: String? = nil) -> String? {
        if let directory = compatibilityManager.bundledShimDirectory() {
            return directory.appendingPathComponent("preload.cjs").path
        }
        #if DEBUG
        if let debugProjectRoot {
            let directory = URL(fileURLWithPath: debugProjectRoot).appendingPathComponent("shim")
            if ["preload.cjs", "patch.cjs"].allSatisfy({
                FileManager.default.isReadableFile(atPath: directory.appendingPathComponent($0).path)
            }) { return directory.appendingPathComponent("preload.cjs").path }
        }
        #endif
        return nil
    }

    func refreshCompatibility() {
        guard compatibilityState != .preparing else { return }
        compatibilityState = compatibilityManager.inspect()
    }

    func prepareCompatibility(completion: @escaping (Result<Void, Error>) -> Void) {
        guard !powerLaunchInProgress else { return }
        guard compatibilityState != .preparing else { return }
        compatibilityState = .preparing
        let manager = compatibilityManager
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<Void, Error>
            do {
                try manager.prepare()
                result = .success(())
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    self.compatibilityState = manager.inspect()
                case let .failure(error):
                    self.compatibilityState = .failed(message: error.localizedDescription)
                }
                completion(result)
            }
        }
    }

    func revealDockEntry() {
        compatibilityManager.revealDockEntry()
    }

    func launch(socketPath: String, stopExistingHost: Bool = true, completion: @escaping (Result<Void, Error>) -> Void) {
        if launchState == .connected && managedRemoteIsRunning {
            reopenRemoteWindow(completion: completion)
            return
        }
        guard case .ready = compatibilityState else {
            completion(.failure(ChatGPTCompatibilityError.verificationFailed("请先准备或修复遥控支持")))
            return
        }
        connectionAttempt = UUID()
        reconnectTimedOut = false
        launchState = .launching
        let appURL = compatibilityManager.patchedAppURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<Void, Error>
            do {
                if stopExistingHost { try Self.stopRunningChatGPT() }
                try Self.launchApp(at: appURL, socketPath: socketPath)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                switch result {
                case .success:
                    if self.launchState != .connected { self.launchState = .waitingForShim }
                    self.scheduleConnectionTimeout()
                case let .failure(error):
                    self.launchState = .failed(message: error.localizedDescription)
                }
                completion(result)
            }
        }
    }

    func launchFromPower(socketPath: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let busy = powerLaunchInProgress || compatibilityState == .preparing
            || launchState == .launching || launchState == .waitingForShim
        guard !busy else { return }
        // Re-read disk and process state; cached connection state alone is insufficient.
        compatibilityState = compatibilityManager.inspect()
        let decision = PowerLaunchDecision.make(
            remoteRunning: managedRemoteIsRunning, connected: launchState == .connected,
            compatibility: compatibilityState, busy: busy, reconnectTimedOut: reconnectTimedOut
        )
        switch decision {
        case .ignore: return
        case .unavailable:
            powerActionDescription = "未找到官方 ChatGPT，无法准备遥控版"
            launchState = .failed(message: powerActionDescription)
            completion(.failure(ChatGPTCompatibilityError.invalidSource(powerActionDescription)))
            return
        case .restoreWindow, .reopenAndWait:
            powerActionDescription = decision == .restoreWindow
                ? "恢复遥控版窗口，不退出当前应用" : "重新打开遥控版窗口，等待连接恢复"
            powerLaunchInProgress = true
            restoreAfterConnect = false
            connectionAttempt = UUID()
            if decision == .reopenAndWait {
                launchState = .waitingForShim
                scheduleConnectionTimeout()
            }
            reopenRemoteWindow { [weak self] result in
                guard let self else { return }
                if case let .failure(error) = result {
                    self.powerLaunchInProgress = false
                    self.connectionAttempt = UUID()
                    // A window error does not invalidate a healthy socket connection.
                    if self.launchState != .connected {
                        self.launchState = .failed(message: error.localizedDescription)
                    }
                } else if decision == .restoreWindow || self.launchState == .connected {
                    self.powerLaunchInProgress = false
                }
                completion(result)
            }
            return
        case .confirmRestart:
            powerLaunchInProgress = true
            let confirmed = confirmRestartOverride?() ?? Self.confirmRemoteRestart()
            powerLaunchInProgress = false
            guard confirmed else {
                powerActionDescription = "已取消重新启动，保留当前应用"
                completion(.success(()))
                return
            }
            // A connection can recover while the confirmation dialog is open.
            if launchState == .connected && managedRemoteIsRunning {
                launchFromPower(socketPath: socketPath, completion: completion)
                return
            }
        case .prepareAndLaunch: break
        }
        // A stale .connected flag must never short-circuit a fresh launch.
        launchState = .idle
        powerActionDescription = "准备并启动 ChatGPT 遥控版"
        reconnectTimedOut = false
        restoreAfterConnect = true
        powerLaunchInProgress = true
        compatibilityState = .preparing
        let manager = compatibilityManager
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try RemoteLaunchPreparation.run(
                    stopHost: Self.stopRunningChatGPT,
                    inspect: manager.inspect,
                    prepare: manager.prepare
                )
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.compatibilityState = manager.inspect()
                    self.launch(socketPath: socketPath, stopExistingHost: false) { result in
                        if case .failure = result {
                            self.powerLaunchInProgress = false
                            self.restoreAfterConnect = false
                        }
                        completion(result)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.powerLaunchInProgress = false
                    self.restoreAfterConnect = false
                    // Failure to quit is a launch failure, not broken compatibility.
                    self.compatibilityState = manager.inspect()
                    self.launchState = .failed(message: error.localizedDescription)
                    completion(.failure(error))
                }
            }
        }
    }

    static func isManagedApp(_ candidate: URL?, at managed: URL) -> Bool {
        guard let candidate else { return false }
        return candidate.resolvingSymlinksInPath().standardizedFileURL
            == managed.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func confirmRemoteRestart() -> Bool {
        let alert = NSAlert()
        alert.messageText = "重新启动 ChatGPT 遥控版？"
        alert.informativeText = "遥控版正在运行，但连接未恢复或遥控支持需要更新、修复。继续会正常退出当前 ChatGPT，必要时更新遥控支持，再重新打开。请先保存工作；退出失败不会强制关闭。"
        alert.addButton(withTitle: "退出并重新打开")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private var managedRemoteIsRunning: Bool {
        if let runningRemoteOverride { return runningRemoteOverride() }
        return NSRunningApplication.runningApplications(
            withBundleIdentifier: ChatGPTShimConfiguration.bundleIdentifier
        ).contains { !$0.isTerminated && Self.isManagedApp($0.bundleURL, at: compatibilityManager.patchedAppURL) }
    }

    static func reopenConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.hides = false
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        return configuration
    }

    private func reopenRemoteWindow(completion: @escaping (Result<Void, Error>) -> Void) {
        let url = compatibilityManager.patchedAppURL
        let request = UUID()
        windowRequest = request
        let finish: (Result<Void, Error>) -> Void = { [weak self] result in
            guard self?.windowRequest == request else { return }
            completion(result)
        }
        if let reopenRemoteOverride {
            reopenRemoteOverride(url, finish)
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: Self.reopenConfiguration()) { app, error in
            DispatchQueue.main.async {
                if let error { finish(.failure(error)) }
                else if app != nil { finish(.success(())) }
                else { finish(.failure(ChatGPTCompatibilityError.commandFailed("未能重新打开遥控版窗口"))) }
            }
        }
    }

    func shimConnectionChanged(_ connected: Bool) {
        if connected {
            connectionAttempt = UUID()
            reconnectTimedOut = false
            launchState = .connected
            if powerLaunchInProgress {
                powerLaunchInProgress = false
                if restoreAfterConnect {
                    restoreAfterConnect = false
                    reopenRemoteWindow { [weak self] result in
                        if case let .failure(error) = result {
                            self?.onWindowError?("遥控已连接，但恢复窗口失败：\(error.localizedDescription)")
                        }
                    }
                }
            }
        } else if launchState == .connected {
            launchState = .failed(message: "ChatGPT 连接已断开")
        }
    }

    private func scheduleConnectionTimeout() {
        let attempt = connectionAttempt
        DispatchQueue.main.asyncAfter(deadline: .now() + connectionTimeout) { [weak self] in
            guard let self, self.connectionAttempt == attempt,
                  self.launchState == .waitingForShim else { return }
            self.powerLaunchInProgress = false
            self.restoreAfterConnect = false
            self.reconnectTimedOut = true
            let message = self.compatibilityState == .sourceMissing
                ? "已请求打开遥控版窗口，但连接未恢复。缺少官方 ChatGPT，暂不能重建遥控支持；当前应用不会被退出。"
                : "遥控版窗口已请求打开，但连接未恢复。再次按 Power 可确认重新启动；请先保存工作。"
            self.launchState = .failed(message: message)
        }
    }

    private static func stopRunningChatGPT() throws {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: ChatGPTShimConfiguration.bundleIdentifier
        )
        for application in running { _ = application.terminate() }
        let deadline = Date().addingTimeInterval(8)
        while running.contains(where: { !$0.isTerminated }) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard running.allSatisfy(\.isTerminated) else {
            throw ChatGPTCompatibilityError.commandFailed("ChatGPT 未能正常退出，请保存工作后手动退出再重试")
        }
    }

    private static func launchApp(at appURL: URL, socketPath: String) throws {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: infoURL),
              let executable = info["CFBundleExecutable"] as? String else {
            throw ChatGPTCompatibilityError.invalidSource("遥控版的启动信息无效")
        }
        let binary = appURL.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw ChatGPTCompatibilityError.invalidSource("遥控版的可执行文件不存在")
        }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: ChatGPTShimConfiguration.logPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let preload = appURL.appendingPathComponent("Contents/Resources")
            .appendingPathComponent(ChatGPTShimConfiguration.shimResourceDirectory)
            .appendingPathComponent("preload.cjs").path
        var environment = ProcessInfo.processInfo.environment
        environment["NODE_OPTIONS"] = "--require \"\(preload)\""
        environment["CODEX_MICRO_SOCKET"] = socketPath
        environment["CODEX_MICRO_SHIM_LOG"] = ChatGPTShimConfiguration.logPath

        let process = Process()
        process.executableURL = binary
        process.currentDirectoryURL = URL(fileURLWithPath: "/tmp")
        process.environment = environment
        try process.run()
    }
}
