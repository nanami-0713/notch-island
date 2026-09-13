import AppKit
import CoreGraphics
import Darwin

/// 拦截媒体键（F1/F2 亮度、静音、F11/F12 音量，系统定义事件），
/// 吃掉系统行为与 Apple 自带 HUD，由灵动岛自己执行并显示进度。
/// 拦截需要"辅助功能"权限：无权限时创建失败，退回"双 HUD"模式。
@MainActor
final class MediaKeyTap {
    enum Key {
        case soundUp, soundDown, mute, brightnessUp, brightnessDown
    }

    /// 返回 true 表示已处理（事件被吃掉）；false 则放行给系统
    var onKey: ((Key) -> Bool)?

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let eventMask: CGEventMask = 1 << 14  // NSSystemDefined

    private static let keyMap: [Int: Key] = [
        0: .soundUp,         // NX_KEYTYPE_SOUND_UP
        1: .soundDown,       // NX_KEYTYPE_SOUND_DOWN
        2: .brightnessUp,    // NX_KEYTYPE_BRIGHTNESS_UP
        3: .brightnessDown,  // NX_KEYTYPE_BRIGHTNESS_DOWN
        7: .mute,            // NX_KEYTYPE_MUTE
    ]

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return controller.consume(event: event, type: type)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(nil, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        runLoopSource = source
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
    }

    nonisolated private func consume(event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated {
                reenable()
                IslandController.debugLog("tap disabled-by-timeout, reenabled")
            }
            return Unmanaged.passUnretained(event)
        }
        return MainActor.assumeIsolated {
            guard let nsEvent = NSEvent(cgEvent: event) else {
                IslandController.debugLog("tap saw event type=\(type.rawValue) but NSEvent(conv) nil")
                return Unmanaged.passUnretained(event)
            }
            let data = nsEvent.data1
            let keyCode = Int((data & 0xFFFF0000) >> 16)
            let keyState = Int((data & 0xFF00) >> 8)  // 0x0A 按下、0x0B 自动重复、0x09 抬起
            guard keyState == 0x0A || keyState == 0x0B, let key = Self.keyMap[keyCode] else {
                return Unmanaged.passUnretained(event)
            }
            return onKey?(key) == true ? nil : Unmanaged.passUnretained(event)
        }
    }

    private func reenable() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}
