import XCTest
import CoreGraphics
import Carbon.HIToolbox
import IOKit.hidsystem
@testable import XiaomiCodexRemote

final class RemoteKeyInterceptionTests: XCTestCase {
    func testSeparateWindowsAndSystemKeyTypes() {
        let interceptor = VolumeKeyInterceptor()
        let system = CGEventType(rawValue: 14)!
        for (key, code) in [("power", Int(NX_POWER_KEY)), ("menu", Int(NX_KEYTYPE_MENU)),
                            ("volume_up", Int(NX_KEYTYPE_SOUND_UP)), ("volume_down", Int(NX_KEYTYPE_SOUND_DOWN))] {
            interceptor.stop()
            XCTAssertFalse(interceptor.shouldSuppress(type: system, keyCode: code, now: 10))
            interceptor.suppressNext(key: key, now: 10)
            XCTAssertTrue(interceptor.shouldSuppress(type: system, keyCode: code, now: 10.1))
            XCTAssertFalse(interceptor.shouldSuppress(type: system, keyCode: code, now: 10.35))
            XCTAssertFalse(interceptor.shouldSuppress(type: system, keyCode: code, subtype: 9, now: 10.1))
            XCTAssertFalse(interceptor.shouldSuppress(type: system, keyCode: Int(NX_KEYTYPE_MUTE), now: 10.1))
            if key != "power" {
                XCTAssertFalse(interceptor.shouldSuppress(type: system, keyCode: Int(NX_POWER_KEY), now: 10.1))
            }
        }
    }

    func testMenuDownUpAndWindowRefresh() {
        let interceptor = VolumeKeyInterceptor()
        interceptor.suppressNext(key: "menu", now: 10)
        for type in [CGEventType.keyDown, .keyUp] {
            XCTAssertTrue(interceptor.shouldSuppress(type: type, keyCode: Int(kVK_ContextualMenu), now: 10.1))
            XCTAssertFalse(interceptor.shouldSuppress(type: type, keyCode: Int(kVK_Return), now: 10.1))
        }
        interceptor.suppressNext(key: "menu", now: 10.3)
        XCTAssertTrue(interceptor.shouldSuppress(type: .keyUp, keyCode: Int(kVK_ContextualMenu), now: 10.5))
        interceptor.stop()
        XCTAssertFalse(interceptor.shouldSuppress(type: .keyUp, keyCode: Int(kVK_ContextualMenu), now: 10.5))
    }
}
