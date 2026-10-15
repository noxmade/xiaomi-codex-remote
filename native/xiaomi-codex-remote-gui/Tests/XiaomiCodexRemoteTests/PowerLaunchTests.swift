import XCTest
@testable import XiaomiCodexRemote

final class PowerLaunchTests: XCTestCase {
    func testCancelledRestartPreservesHostAndSuppressesReentryDuringConfirmation() throws {
        var launcher: ChatGPTLauncher!
        var confirmations = 0
        launcher = makeLauncher(confirm: {
            confirmations += 1
            launcher.launchFromPower(socketPath: "/tmp/unused.sock") { _ in XCTFail("Reentry") }
            return false
        }) { _, _ in XCTFail("Cancel must not reopen or launch") }
        try addOfficialVersion(to: launcher)
        defer { try? FileManager.default.removeItem(at: launcher.compatibilityManager.officialAppURL.deletingLastPathComponent()) }
        launcher.launchFromPower(socketPath: "/tmp/unused.sock") { _ in }
        XCTAssertEqual(confirmations, 1)
        XCTAssertFalse(launcher.powerLaunchInProgress)
        XCTAssertEqual(launcher.launchState, .idle)
        XCTAssertTrue(launcher.powerActionDescription.contains("取消"))
    }

    func testRecoveryDuringConfirmationRestoresInsteadOfRestarting() throws {
        var launcher: ChatGPTLauncher!
        var opens = 0
        launcher = makeLauncher(confirm: {
            launcher.shimConnectionChanged(true)
            return true
        }) { _, completion in opens += 1; completion(.success(())) }
        try addOfficialVersion(to: launcher)
        defer { try? FileManager.default.removeItem(at: launcher.compatibilityManager.officialAppURL.deletingLastPathComponent()) }
        launcher.launchFromPower(socketPath: "/tmp/unused.sock") { _ in }
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(launcher.launchState, .connected)
        XCTAssertFalse(launcher.powerLaunchInProgress)
        XCTAssertTrue(launcher.powerActionDescription.contains("恢复"))
    }

    func testConnectedPowerReopensManagedURLAndSuppressesConcurrentRequests() {
        var opens: [URL] = []
        var finish: ((Result<Void, Error>) -> Void)?
        let launcher = makeLauncher { url, completion in
            opens.append(url)
            finish = completion
        }
        launcher.shimConnectionChanged(true)
        var completed = false
        launcher.launchFromPower(socketPath: "/tmp/unused.sock") { _ in completed = true }
        launcher.launchFromPower(socketPath: "/tmp/unused.sock") { _ in XCTFail("Duplicate request") }
        XCTAssertEqual(opens, [launcher.compatibilityManager.patchedAppURL])
        XCTAssertTrue(launcher.powerLaunchInProgress)
        XCTAssertFalse(completed)
        finish?(.success(()))
        XCTAssertTrue(completed)
        XCTAssertFalse(launcher.powerLaunchInProgress)
        XCTAssertEqual(launcher.launchState, .connected)
    }

    func testTransientDisconnectionWaitsAndConnectionRecoveryClearsBusyState() {
        var opens = 0
        let launcher = makeLauncher { _, completion in
            opens += 1
            completion(.success(()))
        }
        launcher.shimConnectionChanged(true)
        launcher.shimConnectionChanged(false)
        launcher.launchFromPower(socketPath: "/tmp/unused.sock") { _ in }
        XCTAssertEqual(launcher.launchState, .waitingForShim)
        XCTAssertTrue(launcher.powerLaunchInProgress)
        launcher.shimConnectionChanged(true)
        XCTAssertEqual(launcher.launchState, .connected)
        XCTAssertFalse(launcher.powerLaunchInProgress)
        XCTAssertFalse(launcher.reconnectTimedOut)
        XCTAssertEqual(opens, 1, "Connection recovery must not reopen twice")
    }

    func testTimeoutReleasesBusyStateWithoutTerminatingHost() {
        let launcher = makeLauncher(timeout: 0.01) { _, completion in completion(.success(())) }
        launcher.launchFromPower(socketPath: "/tmp/unused.sock") { _ in }
        let expired = expectation(description: "timeout")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertFalse(launcher.powerLaunchInProgress)
            XCTAssertTrue(launcher.reconnectTimedOut)
            guard case .failed = launcher.launchState else { return XCTFail("Expected timeout") }
            expired.fulfill()
        }
        wait(for: [expired], timeout: 1)
    }

    func testReopenFailureSurfacesAndAllowsRetry() {
        let launcher = makeLauncher { _, completion in
            completion(.failure(ChatGPTCompatibilityError.commandFailed("cannot reopen")))
        }
        launcher.shimConnectionChanged(true)
        launcher.launchFromPower(socketPath: "/tmp/unused.sock") { result in
            guard case .failure = result else { return XCTFail("Expected failure") }
        }
        XCTAssertEqual(launcher.launchState, .connected, "Window errors must not mark the socket disconnected")
        XCTAssertFalse(launcher.powerLaunchInProgress)
    }

    func testOldConnectionTimeoutDoesNotFailNewAttempt() {
        let launcher = makeLauncher(timeout: 0.15) { _, completion in completion(.success(())) }
        launcher.launchFromPower(socketPath: "/tmp/unused.sock") { _ in }
        let checked = expectation(description: "old timeout ignored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            launcher.shimConnectionChanged(true)
            launcher.shimConnectionChanged(false)
            launcher.launchFromPower(socketPath: "/tmp/unused.sock") { _ in }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            XCTAssertEqual(launcher.launchState, .waitingForShim)
            XCTAssertTrue(launcher.powerLaunchInProgress)
            launcher.shimConnectionChanged(true)
            checked.fulfill()
        }
        wait(for: [checked], timeout: 1)
    }

    func testConnectedRemoteRestoresWindowEvenWhenCopyNeedsUpdate() {
        XCTAssertEqual(PowerLaunchDecision.make(remoteRunning: true, connected: true,
            compatibility: .needsUpdate(installedVersion: "1", sourceVersion: "2"),
            busy: false, reconnectTimedOut: false), .restoreWindow)
    }

    func testDisconnectedRemoteGetsGracePeriodBeforeConfirmedRestart() {
        XCTAssertEqual(PowerLaunchDecision.make(remoteRunning: true, connected: false,
            compatibility: .ready(version: "1"), busy: false, reconnectTimedOut: false), .reopenAndWait)
        XCTAssertEqual(PowerLaunchDecision.make(remoteRunning: true, connected: false,
            compatibility: .ready(version: "1"), busy: false, reconnectTimedOut: true), .confirmRestart)
    }

    func testMissingOrBrokenCopiesAndStaleConnectionChooseSafeActions() {
        XCTAssertEqual(PowerLaunchDecision.make(remoteRunning: false, connected: true,
            compatibility: .ready(version: "1"), busy: false, reconnectTimedOut: false), .prepareAndLaunch)
        XCTAssertEqual(PowerLaunchDecision.make(remoteRunning: true, connected: false,
            compatibility: .needsRepair(reason: "broken"), busy: false, reconnectTimedOut: false), .confirmRestart)
        XCTAssertEqual(PowerLaunchDecision.make(remoteRunning: false, connected: false,
            compatibility: .needsPreparation(sourceVersion: "1"), busy: false, reconnectTimedOut: false), .prepareAndLaunch)
        XCTAssertEqual(PowerLaunchDecision.make(remoteRunning: false, connected: false,
            compatibility: .sourceMissing, busy: false, reconnectTimedOut: false), .unavailable)
        XCTAssertEqual(PowerLaunchDecision.make(remoteRunning: true, connected: true,
            compatibility: .sourceMissing, busy: true, reconnectTimedOut: false), .ignore)
    }

    func testRunningCopyWithoutOfficialSourceCanStillBeReopened() {
        XCTAssertEqual(PowerLaunchDecision.make(remoteRunning: true, connected: false,
            compatibility: .sourceMissing, busy: false, reconnectTimedOut: true), .reopenAndWait)
    }

    func testReopenConfigurationReusesExactAppAndBringsItForward() {
        let configuration = ChatGPTLauncher.reopenConfiguration()
        XCTAssertTrue(configuration.activates)
        XCTAssertFalse(configuration.hides)
        XCTAssertFalse(configuration.createsNewApplicationInstance)
        XCTAssertFalse(configuration.allowsRunningApplicationSubstitution)
    }

    func testOrdinaryHostPathIsNotTreatedAsManagedRemote() {
        let managed = URL(fileURLWithPath: "/Applications/ChatGPT-for-XiaomiRemote.app")
        XCTAssertFalse(ChatGPTLauncher.isManagedApp(URL(fileURLWithPath: "/Applications/ChatGPT.app"), at: managed))
        XCTAssertTrue(ChatGPTLauncher.isManagedApp(managed, at: managed))
        XCTAssertFalse(ChatGPTLauncher.isManagedApp(nil, at: managed))
    }

    private func makeLauncher(timeout: TimeInterval = 10, confirm: (() -> Bool)? = nil,
                              reopen: @escaping (URL, @escaping (Result<Void, Error>) -> Void) -> Void) -> ChatGPTLauncher {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return ChatGPTLauncher(resourceURL: root,
            officialAppURL: root.appendingPathComponent("ChatGPT.app"),
            patchedAppURL: root.appendingPathComponent("ChatGPT-for-XiaomiRemote.app"),
            runningRemote: { true }, reopenRemote: reopen, connectionTimeout: timeout, confirmRestart: confirm)
    }

    private func addOfficialVersion(to launcher: ChatGPTLauncher) throws {
        let contents = launcher.compatibilityManager.officialAppURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "1"], format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
