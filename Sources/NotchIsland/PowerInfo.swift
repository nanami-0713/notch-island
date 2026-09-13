import AppKit
import Darwin
import IOKit.ps

enum DisplayBrightness {
    private static var readFn: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32)?
    private static var setFn: (@convention(c) (CGDirectDisplayID, Float) -> Int32)?

    /// macOS 15.x 上 CoreDisplay 框架已被整体移除（磁盘与共享缓存都没有），
    /// IODisplayConnect 在 Apple Silicon 上也不存在。
    /// 内建屏亮度走 DisplayServices（缓存驻留，必须用完整 install name 加载）。
    private static func load() {
        if readFn != nil { return }
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let getSymbol = dlsym(handle, "DisplayServicesGetBrightness"),
              let setSymbol = dlsym(handle, "DisplayServicesSetBrightness") else {
            return
        }
        readFn = unsafeBitCast(getSymbol, to: (@convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32).self)
        setFn = unsafeBitCast(setSymbol, to: (@convention(c) (CGDirectDisplayID, Float) -> Int32).self)
    }

    private static func builtInDisplayID() -> CGDirectDisplayID {
        for screen in NSScreen.screens where screen.safeAreaInsets.top > 0 {
            if let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                return id
            }
        }
        return CGMainDisplayID()
    }

    static func read() -> Double? {
        load()
        guard let readFn else { return nil }
        var value: Float = -1
        guard readFn(builtInDisplayID(), &value) == 0, value.isFinite, value >= 0, value <= 1.001 else {
            return nil
        }
        return Double(value)
    }

    @discardableResult
    static func set(_ value: Double) -> Bool {
        load()
        guard let setFn else { return false }
        return setFn(builtInDisplayID(), Float(min(1, max(0, value)))) == 0
    }
}

enum PowerInfo {
    struct Info {
        var charging: Bool
        var percent: Int
    }

    static func read() -> Info? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [Any] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source as! CFTypeRef)?
                .takeUnretainedValue() as? [String: Any],
                let percent = description[kIOPSCurrentCapacityKey] as? Int else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String ?? ""
            let charging = (description[kIOPSIsChargingKey] as? Bool) ?? (state == "AC Power")
            return Info(charging: charging, percent: percent)
        }
        return nil
    }
}
