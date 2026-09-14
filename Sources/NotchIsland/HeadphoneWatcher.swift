import AppKit
import CoreBluetooth
import Foundation
import IOBluetooth

/// 蓝牙耳机连接监听：连接成功时读电量弹岛内动画（alcove 同款场景）。
/// 电量走 IOBluetoothDevice 的 KVO 键（batteryPercentSingle / Left / Right，
/// 单耳耳机用 Single，TWS 左右耳用 Left+Right）；无 KVO 键的 AAC 设备（如部分
/// 私有协议耳机）读不到则只显示连接成功不显示电量。
@MainActor
final class HeadphoneWatcher: NSObject, CBCentralManagerDelegate {
    struct Snapshot: Equatable {
        var name: String
        var percent: Int?
        var isTWS: Bool
    }

    var onConnected: ((Snapshot) -> Void)?
    var onDisconnected: ((String) -> Void)?

    private var connectedAddresses: Set<String> = []
    private var pollTimer: Timer?
    /// 用于触发 TCC「蓝牙」权限请求（初始化即触发系统授权弹窗/状态查询）
    private var centralManager: CBCentralManager?

    func start() {
        // 枚举配对设备需要 TCC「蓝牙」权限，未授权会直接崩溃；
        // 初始化 CBCentralManager 触发授权，回调里按状态启动
        centralManager = CBCentralManager(delegate: self, queue: .main)
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        NotificationCenter.default.removeObserver(self)
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard state == .poweredOn || state == .poweredOff else { return }  // unauthorized 不启动
                self.registerObservers()
                self.pollTimer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.poll() }
                }
                RunLoop.main.add(self.pollTimer!, forMode: .common)
                self.poll()
            }
        }
    }

    private func registerObservers() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(deviceConnected(_:)),
            name: Notification.Name("IOBluetoothDeviceConnectedNotification"),
            object: nil
        )
        center.addObserver(
            self, selector: #selector(deviceDisconnected(_:)),
            name: Notification.Name("IOBluetoothDeviceDisconnectedNotification"),
            object: nil
        )
    }

    @objc private func deviceConnected(_ note: Notification) {
        guard let device = note.userInfo?["kIOBluetoothUserNotificationDeviceKey"] as? IOBluetoothDevice else { return }
        handleConnect(address: device.addressString, name: device.name ?? "蓝牙耳机", device: device)
    }

    @objc private func deviceDisconnected(_ note: Notification) {
        guard let device = note.userInfo?["kIOBluetoothUserNotificationDeviceKey"] as? IOBluetoothDevice else { return }
        handleDisconnect(address: device.addressString, name: device.name ?? "蓝牙耳机")
    }

    private func poll() {
        guard let list = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }
        var nowConnected: Set<String> = []
        for device in list where device.isConnected() {
            nowConnected.insert(device.addressString)
            if !connectedAddresses.contains(device.addressString) {
                handleConnect(address: device.addressString, name: device.name ?? "蓝牙耳机", device: device)
            }
        }
        for address in connectedAddresses where !nowConnected.contains(address) {
            handleDisconnect(address: address, name: address)
        }
        connectedAddresses = nowConnected
    }

    private func handleConnect(address: String, name: String, device: IOBluetoothDevice) {
        guard !connectedAddresses.contains(address) else { return }
        connectedAddresses.insert(address)
        let snapshot = readBattery(device, name: name)
        IslandController.debugLog("headphone connected \(name) percent=\(snapshot.percent.map(String.init) ?? "nil")")
        onConnected?(snapshot)
    }

    private func handleDisconnect(address: String, name: String) {
        guard connectedAddresses.contains(address) else { return }
        connectedAddresses.remove(address)
        IslandController.debugLog("headphone disconnected \(name)")
        onDisconnected?(name)
    }

    private func readBattery(_ device: IOBluetoothDevice, name: String) -> Snapshot {
        func percent(_ key: String) -> Int {
            let value = device.value(forKey: key)
            if let n = value as? Int, n > 0 { return n }
            return 0
        }
        let left = percent("batteryPercentLeft")
        let right = percent("batteryPercentRight")
        let single = percent("batteryPercentSingle")
        let isTWS = left > 0 || right > 0
        let percent: Int?
        if isTWS {
            let min2 = [left, right].filter { $0 > 0 }.min()
            percent = min2
        } else if single > 0 {
            percent = single
        } else {
            percent = nil
        }
        return Snapshot(name: name, percent: percent, isTWS: isTWS)
    }
}
