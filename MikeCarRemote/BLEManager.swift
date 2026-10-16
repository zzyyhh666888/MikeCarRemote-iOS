//
//  BLEManager.swift
//  MikeCarRemote
//
//  蓝牙 BLE 透传连接管理。兼容市面上常见的 BLE 串口透传模块:
//  - HM-10 / HC-08 / AT-09 / JDY-08 / JDY-25M / CH9141 (0xFFE0 / 0xFFE1)
//  - Nordic UART Service (6E400001..., TX=...002 写, RX=...003 通知)
//  - RN4870 / 信驰达等 (49535343-...)
//  找不到已知 UUID 时，按特征属性自动挑选“可写 + 可通知”的透传通道。
//

import CoreBluetooth
import SwiftUI

struct BLEDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String
    var rssi: NSNumber
}

enum BLEConnectionState: Equatable {
    case disconnected
    case scanning
    case connecting
    case discovering        // 已连接，正在发现透传服务
    case ready              // 透传通道就绪，可以发送
    case bluetoothOff
    case unavailable(String)
}

@MainActor
final class BLEManager: NSObject, ObservableObject {

    // MARK: - 发布状态

    @Published private(set) var devices: [BLEDevice] = []
    @Published private(set) var state: BLEConnectionState = .disconnected
    @Published private(set) var connectedName: String?
    @Published private(set) var lastError: String?
    @Published private(set) var rxByteCount: Int = 0

    // 诊断信息（显示在界面上，用于判断数据是否走对了透传通道）
    @Published private(set) var connectedDeviceName: String?
    @Published private(set) var serviceUUIDs: [String] = []
    @Published private(set) var txCharacteristicUUID: String?
    @Published private(set) var rxCharacteristicUUID: String?
    @Published private(set) var sentFrameCount: Int = 0

    // MARK: - 私有属性

    private var central: CBCentralManager!
    private var connectingPeripheral: CBPeripheral?
    private var connectedPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?
    private var pendingServiceCount = 0
    private var notifyEnabled = false

    private let savedPeripheralKey = "MikeCarRemote.savedPeripheralUUID"
    private var scanTimeoutWorkItem: DispatchWorkItem?

    // 常见透传 GATT UUID（HM-10/HC-08/JDY/CH9141/DX-BT/BT04-BLE/NUS 等）
    private static let knownWriteUUIDs: Set<CBUUID> = [
        CBUUID(string: "FFE1"),
        CBUUID(string: "FFE2"),
        CBUUID(string: "FFF1"),
        CBUUID(string: "FFF2"),
        CBUUID(string: "FF01"),
        CBUUID(string: "FE61"),
        CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"),
        CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3"),
        CBUUID(string: "0000FFE1-0000-1000-8000-00805F9B34FB")
    ]
    private static let knownNotifyUUIDs: Set<CBUUID> = [
        CBUUID(string: "FFE1"),
        CBUUID(string: "FFE4"),
        CBUUID(string: "FFF1"),
        CBUUID(string: "FFF4"),
        CBUUID(string: "FF01"),
        CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"),
        CBUUID(string: "49535343-1E4D-4BD9-BA61-23C647249616"),
        CBUUID(string: "0000FFE1-0000-1000-8000-00805F9B34FB")
    ]
    private static let knownServiceUUIDs: [CBUUID] = [
        CBUUID(string: "FFE0"),
        CBUUID(string: "FFF0"),
        CBUUID(string: "00FF"),
        CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"),
        CBUUID(string: "49535343-1E4D-4BD9-BA61-23C647249616")
    ]

    var isReady: Bool { state == .ready }

    override init() {
        super.init()
        // queue 为 nil 时回调在主线程，和 SwiftUI 状态更新在同一线程
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - 扫描 / 连接 / 断开

    func startScan() {
        guard central.state == .poweredOn else {
            lastError = "蓝牙未开启，请在系统设置中打开蓝牙"
            return
        }
        lastError = nil
        devices.removeAll()
        central.stopScan()
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        state = .scanning

        scanTimeoutWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.central.isScanning { self.central.stopScan() }
            if self.state == .scanning { self.state = .disconnected }
        }
        scanTimeoutWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    /// 供界面清除错误提示
    func clearError() {
        lastError = nil
    }

    func stopScan() {
        scanTimeoutWorkItem?.cancel()
        if central.isScanning { central.stopScan() }
        if state == .scanning { state = .disconnected }
    }

    func connect(_ device: BLEDevice) {
        stopScan()
        lastError = nil
        connectingPeripheral = device.peripheral
        state = .connecting
        central.connect(device.peripheral, options: nil)
        UserDefaults.standard.set(device.id.uuidString, forKey: savedPeripheralKey)
    }

    func disconnect() {
        scanTimeoutWorkItem?.cancel()
        if let p = connectedPeripheral ?? connectingPeripheral {
            central.cancelPeripheralConnection(p)
        }
        connectingPeripheral = nil
        connectedPeripheral = nil
        txCharacteristic = nil
        rxCharacteristic = nil
        notifyEnabled = false
        connectedName = nil
        connectedDeviceName = nil
        serviceUUIDs = []
        txCharacteristicUUID = nil
        rxCharacteristicUUID = nil
        sentFrameCount = 0
        state = .disconnected
    }

    /// 发送数据，自动按 MTU 分包
    func send(_ data: Data) {
        guard let peripheral = connectedPeripheral,
              let tx = txCharacteristic,
              state == .ready,
              !data.isEmpty else { return }

        let writeType: CBCharacteristicWriteType =
            tx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let chunkSize = max(20, peripheral.maximumWriteValueLength(for: writeType))

        var index = 0
        while index < data.count {
            let end = min(index + chunkSize, data.count)
            peripheral.writeValue(data.subdata(in: index..<end), for: tx, type: writeType)
            index = end
        }
        sentFrameCount += 1
    }

    // MARK: - 自动重连上次设备

    private func tryAutoConnect() {
        guard let saved = UserDefaults.standard.string(forKey: savedPeripheralKey),
              let uuid = UUID(uuidString: saved) else { return }

        if let known = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            connectingPeripheral = known
            state = .connecting
            central.connect(known, options: nil)
            return
        }
        // 设备可能已被系统连接（透传模块重连后常见）
        for serviceUUID in Self.knownServiceUUIDs {
            if let linked = central.retrieveConnectedPeripherals(withServices: [serviceUUID]).first {
                connectingPeripheral = linked
                state = .connecting
                central.connect(linked, options: nil)
                return
            }
        }
    }

    // MARK: - 透传特征挑选

    fileprivate func resolveTransport(for peripheral: CBPeripheral) {
        struct Candidate {
            let service: CBService
            let char: CBCharacteristic
        }

        let services = peripheral.services ?? []
        var candidates: [Candidate] = []
        for service in services {
            for char in service.characteristics ?? [] {
                candidates.append(Candidate(service: service, char: char))
            }
        }

        func writable(_ c: CBCharacteristic) -> Bool {
            c.properties.contains(.write) || c.properties.contains(.writeWithoutResponse)
        }
        func notifiable(_ c: CBCharacteristic) -> Bool {
            c.properties.contains(.notify) || c.properties.contains(.indicate)
        }
        // OTA / DFU 升级服务不是透传通道，必须排除（选错会导致能连上但控制完全无效）
        func likelyUpgradeService(_ s: CBService) -> Bool {
            let id = s.uuid.uuidString.lowercased()
            return id.contains("dfu") || id.contains("ota") || id.contains("firmware") || id.contains("upgrade")
        }

        let writeCandidates = candidates.filter {
            writable($0.char) && !likelyUpgradeService($0.service)
        }

        // 打分挑出真正的透传写特征：
        // 已知 UUID 100 分；同一特征同时可写+可通知（FFE1 型）+40；
        // 同服务内有成对通知特征（NUS 型 RX/TX 分离）+20；支持无响应写 +5
        func score(_ item: Candidate) -> Int {
            var s = 0
            if Self.knownWriteUUIDs.contains(item.char.uuid) { s += 100 }
            if notifiable(item.char) { s += 40 }
            let siblingNotify = (item.service.characteristics ?? []).contains {
                $0.uuid != item.char.uuid && notifiable($0)
            }
            if siblingNotify { s += 20 }
            if item.char.properties.contains(.writeWithoutResponse) { s += 5 }
            return s
        }

        guard let best = writeCandidates.max(by: { score($0) < score($1) }) else {
            lastError = "该设备没有可用的透传通道，请确认是 BLE 串口透传模块"
            disconnect()
            state = .disconnected
            return
        }

        // 接收（通知）特征：优先和写特征同特征，其次同服务内的，最后全局已知 UUID
        var rx: CBCharacteristic?
        if notifiable(best.char) {
            rx = best.char
        } else {
            rx = (best.service.characteristics ?? []).first { notifiable($0) }
            if rx == nil {
                rx = candidates.first {
                    notifiable($0.char) && Self.knownNotifyUUIDs.contains($0.char.uuid)
                }?.char
            }
            if rx == nil {
                rx = candidates.first { notifiable($0.char) }?.char
            }
        }

        // 记录诊断信息
        connectedDeviceName = peripheral.name
        serviceUUIDs = services.map { $0.uuid.uuidString }
        txCharacteristic = best.char
        rxCharacteristic = rx
        txCharacteristicUUID = best.char.uuid.uuidString
        rxCharacteristicUUID = rx?.uuid.uuidString

        if let rx {
            peripheral.setNotifyValue(true, for: rx)
        } else {
            // 没有通知通道也可以单向发送控制帧
            notifyEnabled = true
            state = .ready
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let newState = central.state
        Task { @MainActor in
            switch newState {
            case .poweredOn:
                self.tryAutoConnect()
            case .poweredOff:
                self.state = .bluetoothOff
            case .unauthorized:
                self.state = .unavailable("未授予蓝牙权限，请在系统设置中允许")
            case .unsupported:
                self.state = .unavailable("本机不支持蓝牙低功耗")
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
        let name = peripheral.name ?? advertisedName ?? "未命名设备"
        Task { @MainActor in
            if let index = self.devices.firstIndex(where: { $0.id == peripheral.identifier }) {
                self.devices[index].rssi = RSSI
            } else {
                self.devices.append(BLEDevice(id: peripheral.identifier,
                                              peripheral: peripheral,
                                              name: name,
                                              rssi: RSSI))
                self.devices.sort { lhs, rhs in
                    let l = lhs.rssi.intValue == 127 ? -200 : lhs.rssi.intValue
                    let r = rhs.rssi.intValue == 127 ? -200 : rhs.rssi.intValue
                    return l > r
                }
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.connectingPeripheral = nil
            self.connectedPeripheral = peripheral
            self.connectedName = peripheral.name
            self.txCharacteristic = nil
            self.rxCharacteristic = nil
            self.notifyEnabled = false
            self.state = .discovering
            peripheral.delegate = self
            peripheral.discoverServices(nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.lastError = "连接失败：\(error?.localizedDescription ?? "未知错误")"
            self.connectingPeripheral = nil
            self.state = .disconnected
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.connectedPeripheral = nil
            self.txCharacteristic = nil
            self.rxCharacteristic = nil
            self.notifyEnabled = false
            self.connectedName = nil
            if self.state != .scanning {
                self.state = .disconnected
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                self.lastError = "发现服务失败：\(error.localizedDescription)"
                self.disconnect()
                return
            }
            let services = peripheral.services ?? []
            guard !services.isEmpty else {
                self.lastError = "设备没有广播任何 GATT 服务"
                self.disconnect()
                return
            }
            self.pendingServiceCount = services.count
            for service in services {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            self.pendingServiceCount -= 1
            if self.pendingServiceCount <= 0 {
                self.resolveTransport(for: peripheral)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            if let error {
                self.lastError = "订阅通知失败：\(error.localizedDescription)"
            }
            self.notifyEnabled = characteristic.isNotifying
            if self.state != .ready {
                self.state = .ready
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value else { return }
        Task { @MainActor in
            // 固件会通过同一串口回传调试打印，这里仅统计流量，不解析
            self.rxByteCount += data.count
        }
    }
}
