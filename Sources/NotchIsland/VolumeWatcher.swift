import CoreAudio
import Darwin

/// 监听默认输出设备的音量/静音变化（F11/F12），零权限
final class VolumeWatcher {
    var onChange: ((Float, Bool) -> Void)?

    private var device: AudioDeviceID = 0
    private let queue = DispatchQueue.main

    func start() {
        subscribeDefaultDevice()
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue) { [weak self] _, _ in
            guard let self else { return }
            self.subscribeDefaultDevice()
            self.emit()
        }
    }

    private func subscribeDefaultDevice() {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else {
            return
        }
        guard id != device else { return }
        if device != 0 { unsubscribe(device) }
        device = id

        // 多数设备没有主音量元素，音量变化落在通道 1/2 上，所以多元素多 scope 都注册
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
        let scopes: [AudioObjectPropertyScope] = [kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyScopeOutput]
        for scope in scopes {
            for element in elements {
                var volumeAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: scope,
                    mElement: element
                )
                AudioObjectAddPropertyListenerBlock(device, &volumeAddress, queue) { [weak self] _, _ in
                    self?.emit()
                }
                var muteAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyMute,
                    mScope: scope,
                    mElement: element
                )
                AudioObjectAddPropertyListenerBlock(device, &muteAddress, queue) { [weak self] _, _ in
                    self?.emit()
                }
            }
        }
    }

    private func unsubscribe(_ id: AudioDeviceID) {
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
        let scopes: [AudioObjectPropertyScope] = [kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyScopeOutput]
        for scope in scopes {
            for element in elements {
                var volumeAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: scope,
                    mElement: element
                )
                AudioObjectRemovePropertyListenerBlock(id, &volumeAddress, queue) { _, _ in }
                var muteAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyMute,
                    mScope: scope,
                    mElement: element
                )
                AudioObjectRemovePropertyListenerBlock(id, &muteAddress, queue) { _, _ in }
            }
        }
    }

    private func volumeScalar() -> Float? {
        guard device != 0 else { return nil }
        var size = UInt32(MemoryLayout<Float32>.size)
        // 内建扬声器音量挂在 Output scope 下；其他设备多在 Global/通道
        for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeGlobal] {
            var master = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            var value = Float(-1)
            if AudioObjectGetPropertyData(device, &master, 0, nil, &size, &value) == noErr, value >= 0 {
                return value
            }
            var best = Float(-1)
            for element: UInt32 in 1...2 {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: scope,
                    mElement: element
                )
                var channelValue = Float(0)
                if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &channelValue) == noErr {
                    best = max(best, channelValue)
                }
            }
            if best >= 0 { return best }
        }
        return nil
    }

    private func isMuted() -> Bool {
        guard device != 0 else { return false }
        var size = UInt32(MemoryLayout<UInt32>.size)
        for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeGlobal] {
            for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1)] {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyMute,
                    mScope: scope,
                    mElement: element
                )
                var mutedValue: UInt32 = 0
                if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &mutedValue) == noErr {
                    return mutedValue != 0
                }
            }
        }
        return false
    }

    // MARK: - 媒体键直接调音量

    /// ±步进调整音量；返回是否成功写入设备
    func adjustVolume(_ delta: Float) -> Bool {
        guard device != 0, let current = volumeScalar() else { return false }
        return setVolumeRaw(max(0, min(1, current + delta)))
    }

    @discardableResult
    func toggleMute() -> Bool {
        guard device != 0 else { return false }
        return setMuted(!isMuted())
    }

    private func setVolumeRaw(_ value: Float) -> Bool {
        var size = UInt32(MemoryLayout<Float32>.size)
        var v = value
        for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeGlobal] {
            var main = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: scope,
                mElement: kAudioObjectPropertyElementMain
            )
            if AudioObjectHasProperty(device, &main),
               AudioObjectSetPropertyData(device, &main, 0, nil, size, &v) == noErr {
                return true
            }
        }
        // 双通道设备：分别写左右声道
        for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeGlobal] {
            var wrote = false
            for element: UInt32 in 1...2 {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: scope,
                    mElement: element
                )
                if AudioObjectHasProperty(device, &address),
                   AudioObjectSetPropertyData(device, &address, 0, nil, size, &v) == noErr {
                    wrote = true
                }
            }
            if wrote { return true }
        }
        return false
    }

    private func setMuted(_ muted: Bool) -> Bool {
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = muted ? 1 : 0
        for scope in [kAudioObjectPropertyScopeOutput, kAudioObjectPropertyScopeGlobal] {
            for element in [kAudioObjectPropertyElementMain, AudioObjectPropertyElement(1)] {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyMute,
                    mScope: scope,
                    mElement: element
                )
                if AudioObjectHasProperty(device, &address),
                   AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr {
                    return true
                }
            }
        }
        return false
    }

    private func emit() {
        guard let volume = volumeScalar() else { return }
        let muted = isMuted()
        onChange?(muted ? 0 : volume, muted)
    }
}
