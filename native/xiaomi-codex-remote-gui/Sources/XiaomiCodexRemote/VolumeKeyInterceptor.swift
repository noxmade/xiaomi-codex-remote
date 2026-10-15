import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import IOKit.hidsystem
import Carbon.HIToolbox

/// Short-lived system-event suppression after remote input. The time window
/// does not identify the source device, so matching keyboard events may overlap.
@Observable
final class VolumeKeyInterceptor {
    private(set) var isEnabled: Bool = false
    private(set) var isTrusted: Bool = false
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var suppressionDeadlines: [String: TimeInterval] = [:]

    init() {
        _ = checkAccessibility()
    }

    deinit {
        stop()
    }

    @discardableResult
    func checkAccessibility() -> Bool {
        isTrusted = AXIsProcessTrusted()
        return isTrusted
    }

    func requestAccessibility() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options)
    }

    /// Volume keys retain their shared window; power and menu have separate windows.
    func suppressNext(key: String = "volume_up", duration: TimeInterval = 0.35,
                      now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let group = Self.group(for: key) else { return }
        suppressionDeadlines[group] = now + duration
    }

    private static func group(for key: String) -> String? {
        switch key {
        case "volume_up", "volume_down": return "volume"
        case "power", "menu": return key
        default: return nil
        }
    }

    func shouldSuppress(type: CGEventType, keyCode: Int, subtype: Int = 8,
                        now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        let group: String
        if type.rawValue == 14, subtype == 8 {
            switch keyCode {
            case Int(NX_KEYTYPE_SOUND_UP), Int(NX_KEYTYPE_SOUND_DOWN): group = "volume"
            case Int(NX_POWER_KEY): group = "power"
            case Int(NX_KEYTYPE_MENU): group = "menu"
            default: return false
            }
        } else if (type == .keyDown || type == .keyUp), keyCode == Int(kVK_ContextualMenu) {
            group = "menu"
        } else {
            return false
        }
        return now < (suppressionDeadlines[group] ?? 0)
    }

    func start() {
        guard machPort == nil else { return }
        guard checkAccessibility() else {
            print("[VolumeInterceptor] Accessibility permission not granted; remote system keys will not be intercepted")
            return
        }

        let eventMask: CGEventMask = (1 << 14) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passRetained(event) }
                let interceptor = Unmanaged<VolumeKeyInterceptor>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let port = interceptor.machPort {
                        CGEvent.tapEnable(tap: port, enable: true)
                    }
                    return Unmanaged.passRetained(event)
                }

                if type.rawValue == 14, let nsEvent = NSEvent(cgEvent: event) {
                    let keyCode = Int((nsEvent.data1 & 0xFFFF0000) >> 16)
                    if interceptor.shouldSuppress(type: type, keyCode: keyCode, subtype: Int(nsEvent.subtype.rawValue)) {
                        return nil
                    }
                } else if type == .keyDown || type == .keyUp {
                    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
                    if interceptor.shouldSuppress(type: type, keyCode: keyCode) {
                        return nil
                    }
                }

                return Unmanaged.passRetained(event)
            },
            userInfo: context
        ) else {
            print("[VolumeInterceptor] Failed to create CGEventTap")
            return
        }

        self.machPort = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.isEnabled = true
        print("[VolumeInterceptor] Active: Xiaomi remote volume, power and menu system-key interception enabled")
    }

    func stop() {
        if let tap = machPort {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
                self.runLoopSource = nil
            }
            self.machPort = nil
        }
        suppressionDeadlines.removeAll()
        self.isEnabled = false
    }
}
