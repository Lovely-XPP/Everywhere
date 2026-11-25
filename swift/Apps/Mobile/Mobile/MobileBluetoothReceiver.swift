import CoreBluetooth
import SwiftUI

/// 支持前后台蓝牙事件的 BLE 接收端。在主队列校验加密写入，更新应用位置后给 Mac 返回 ATT 回执。
final class MobileBluetoothReceiver: NSObject, ObservableObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate, CBPeripheralDelegate {
    /// 当前订阅定位服务的对端。接收码及最近一条坐标回执独立于连接状态。
    @Published private(set) var connectedPeers: Set<UUID> = []
    var isConnected: Bool { !connectedPeers.isEmpty }
    @Published private(set) var viewingIAP2 = false
    @Published private(set) var report: IAP2ConnectionReport?
    var connectionLabel: String {
        if viewingIAP2 {
            if report?.authenticated == true { return "Mac 报告 · iAP2 已连接" }
            return report == nil ? "正在读取 Mac 会话" : "已连接 Mac 状态通道"
        }
        if connectedPeers.count > 1 { return "蓝牙已连接 · \(connectedPeers.count) 台主机" }
        if let id = connectedPeers.first { return "蓝牙已连接 · " + (macs[id] ?? "Mac") }
        return enabled ? "蓝牙尚未连接" : "蓝牙接收已关闭"
    }

    @Published private(set) var enabled = false
    @Published private(set) var status = "接收已关闭"
    @Published private(set) var code = ""
    @Published private var inbox = BluetoothPointInbox()
    var point: GeoPoint? { inbox.point }
    @Published private(set) var pointReceivedAt: Date?

    /// 两个 GATT 方向共用同一回执语义：仅确认本应用收到了坐标。
    private func receive(_ data: Data, from peer: UUID) throws {
        try inbox.receive(data, code: code, from: peer)
        pointReceivedAt = point == nil ? nil : Date()
        status = point == nil ? "已清除 Everywhere 地图标记" : "已更新 Everywhere 地图标记；系统坐标请查看「本机定位来源」。"
    }
    private var manager: CBPeripheralManager?

    @Published private(set) var macs: [UUID: String] = [:]
    @Published private(set) var scanningMacs = false
    private var central: CBCentralManager?
    private var found: [UUID: CBPeripheral] = [:]
    private var selected: CBPeripheral?
    private var subscribedCommand: CBCharacteristic?
    private var ack: CBCharacteristic?
    private var connectTimeout: DispatchWorkItem?
    private let statusService = CBUUID(string: IAP2ConnectionReport.serviceID)
    private let statusField = CBUUID(string: IAP2ConnectionReport.fieldID)
    private var readingReport = false
    private var reportChanged = false
    private let reverseService = CBUUID(string: BluetoothPointCommand.reverseServiceID)

    /// 手机作为中心设备扫描主动广播的 Mac。仅连接用户点选的设备。
    func scanMacs() {
        guard !enabled else { return }
        enabled = true
        scanningMacs = true
        code = String(Int.random(in: 100000...999999))
        status = "正在准备扫描 Mac…"
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func chooseMac(_ id: UUID) {
        guard let central, central.state == .poweredOn, selected == nil, let peer = found[id] else { return }
        central.stopScan()
        selected = peer
        peer.delegate = self
        status = "正在连接 " + (macs[id] ?? "Mac")
        central.connect(peer, options: [CBConnectPeripheralOptionEnableAutoReconnect: true])
        let deadline = DispatchWorkItem { [weak self, weak peer] in
            guard let self, let peer, self.selected === peer else { return }
            self.restartScan("蓝牙握手超时，请重新选择 Mac。")
        }
        connectTimeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: deadline)
    }

    private func restartScan(_ message: String) {
        clearReport()
        connectedPeers.removeAll()
        connectTimeout?.cancel()
        connectTimeout = nil
        if let selected {
            selected.delegate = nil
            if central?.state == .poweredOn { central?.cancelPeripheralConnection(selected) }
        }
        selected = nil
        subscribedCommand = nil
        ack = nil
        pointReceivedAt = nil
        inbox = BluetoothPointInbox()
        found.removeAll()
        macs.removeAll()
        status = message
        if central?.state == .poweredOn { central?.scanForPeripherals(withServices: [reverseService, statusService]) }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard self.central === central else { return }
        restartScan(central.state == .poweredOn ? "正在扫描 Mac，请选择要连接的主机。" : "蓝牙尚未就绪，请检查开关与蓝牙权限。")
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard self.central === central, selected == nil else { return }
        found[peripheral.identifier] = peripheral
        macs[peripheral.identifier] = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Everywhere Mac"
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard selected === peripheral else { return }
        peripheral.discoverServices([reverseService, statusService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if selected === peripheral { restartScan(error?.localizedDescription ?? "未能连接 Mac，请重新选择。") }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if selected === peripheral { restartScan("Mac 已断开，请重新选择。") }
    }

    /// 系统重连期间保留用户选定的 Mac 和当轮接收码。重新连通后再次发现服务并订阅。
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        timestamp: CFAbsoluteTime, isReconnecting: Bool, error: Error?) {
        guard self.central === central, selected === peripheral else { return }
        clearReport()
        connectedPeers.remove(peripheral.identifier)
        if isReconnecting {
            connectTimeout?.cancel()
            subscribedCommand = nil
            ack = nil
            status = "蓝牙暂时断开，正在重连所选 Mac…"
        } else {
            restartScan("Mac 已断开，请重新选择。")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard selected === peripheral else { return }
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == statusService })
                ?? peripheral.services?.first(where: { $0.uuid == reverseService }) else {
            restartScan("Mac 未提供 Everywhere 蓝牙服务。"); return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard selected === peripheral else { return }
        if service.uuid == statusService {
            guard error == nil, let field = service.characteristics?.first(where: { $0.uuid == statusField }) else {
                restartScan("Mac 会话状态通道不可用。"); return
            }
            viewingIAP2 = true
            subscribedCommand = field
            peripheral.setNotifyValue(true, for: field)
            return
        }
        guard error == nil, let fields = service.characteristics,
              let command = fields.first(where: { $0.uuid == CBUUID(string: BluetoothPointCommand.rmcID) })
                ?? fields.first(where: { $0.uuid == CBUUID(string: BluetoothPointCommand.commandID) }),
              let receipt = fields.first(where: { $0.uuid == CBUUID(string: BluetoothPointCommand.receiptID) }) else {
            restartScan("Mac 的定位或回执通道不可用。"); return
        }
        subscribedCommand = command
        ack = receipt
        peripheral.setNotifyValue(true, for: command)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard selected === peripheral else { return }
        guard characteristic === subscribedCommand else { return }
        guard characteristic.isNotifying, error == nil else { restartScan("蓝牙订阅失败，请核对系统配对提示。"); return }
        connectTimeout?.cancel()
        connectedPeers.insert(peripheral.identifier)
        if characteristic.uuid == statusField { refreshReport() }
        else { status = "请在 Mac 输入本机接收码以发送坐标。" }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == statusField {
            guard selected === peripheral, characteristic === subscribedCommand else { return }
            guard error == nil, let data = characteristic.value else { restartScan("读取 Mac 状态失败，请重新连接。"); return }
            if data == Data([0]) { refreshReport(); return }
            guard let update = try? JSONDecoder().decode(IAP2ConnectionReport.self, from: data) else {
                restartScan("Mac 状态格式无法识别，请更新两端 Everywhere。"); return
            }
            connectTimeout?.cancel()
            readingReport = false
            report = update
            status = update.target.isEmpty ? update.message : "Mac 所选设备：" + update.target + " · " + update.message
            if reportChanged { reportChanged = false; refreshReport() }
            return
        }
        guard selected === peripheral, characteristic === subscribedCommand,
              error == nil, let packet = characteristic.value, packet.count >= 4, let ack else { return }
        var reply = Data(packet.prefix(4))
        do {
            try receive(Data(packet.dropFirst(4)), from: peripheral.identifier)
            reply.append(0)
        } catch {
            status = "命令被拒绝，请核对接收码。"
            reply.append(1)
        }
        peripheral.writeValue(reply, for: ack, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if selected === peripheral, let error { status = "回执发送失败 · " + error.localizedDescription }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        let activeService = viewingIAP2 ? statusService : reverseService
        if selected === peripheral, invalidatedServices.contains(where: { $0.uuid == activeService }) {
            restartScan("Mac 的蓝牙服务已重启，请重新选择。")
        }
    }

    /// 状态特征的通知只说明内容已变；订阅成功、收到通知或回到前台时读取最新快照。
    func refreshReport() {
        guard viewingIAP2, let selected, let field = subscribedCommand, field.isNotifying else { return }
        guard !readingReport else { reportChanged = true; return }
        readingReport = true
        connectTimeout?.cancel()
        let deadline = DispatchWorkItem { [weak self] in self?.restartScan("Mac 状态读取超时，请重新连接。") }
        connectTimeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: deadline)
        selected.readValue(for: field)
    }

    private func clearReport() {
        readingReport = false
        reportChanged = false
        viewingIAP2 = false
        report = nil
    }

    /// 手机本地恢复与远端清除共享同一位置状态。
    func clearLocalPoint() {
        pointReceivedAt = nil
        inbox.clearLocalPoint()
        status = "已移除蓝牙位置，等待 Mac 发送新位置"
    }

    func start() {
        guard !enabled else { return }
        enabled = true
        status = "正在准备蓝牙"
        code = String(Int.random(in: 100000...999999))
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }

    /// 停止广播并撤销本轮接收码和位置；延迟到达的旧管理器回调不再生效。
    func stop() {
        clearReport()
        connectedPeers.removeAll()
        connectTimeout?.cancel()
        connectTimeout = nil
        central?.delegate = nil
        if central?.state == .poweredOn {
            central?.stopScan()
            if let selected { central?.cancelPeripheralConnection(selected) }
        }
        selected?.delegate = nil
        central = nil
        selected = nil
        subscribedCommand = nil
        ack = nil
        scanningMacs = false
        found.removeAll()
        macs.removeAll()
        let old = manager
        manager = nil
        if old?.state == .poweredOn { old?.stopAdvertising(); old?.removeAllServices() }
        enabled = false
        code = ""
        pointReceivedAt = nil
        inbox = BluetoothPointInbox()
        status = "接收已关闭"
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard manager === peripheral else { return }
        guard peripheral.state == .poweredOn else {
            clearReport()
            connectedPeers.removeAll()
            status = peripheral.state == .unauthorized ? "请在系统设置中允许蓝牙权限" : "蓝牙尚不可用"
            return
        }
        let service = CBMutableService(type: CBUUID(string: BluetoothPointCommand.serviceID), primary: true)
        let capability = CBMutableCharacteristic(type: CBUUID(string: BluetoothPointCommand.rmcID),
            properties: [.read], value: Data([1]), permissions: [.readable])
        service.characteristics = [capability, CBMutableCharacteristic(type: CBUUID(string: BluetoothPointCommand.commandID),
            properties: [.write, .notify, .notifyEncryptionRequired], value: nil, permissions: [.writeEncryptionRequired])]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard manager === peripheral else { return }
        if let error { status = error.localizedDescription; return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service.uuid],
                                    CBAdvertisementDataLocalNameKey: "Everywhere"])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard manager === peripheral else { return }
        if let error { status = error.localizedDescription }
        else if !isConnected { status = "正在广播，等待 Mac 连接。" }
    }

    /// Mac 发起连接时，由 Core Bluetooth 订阅回调确认通道，首条坐标到达前即可显示状态。
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        guard manager === peripheral, characteristic.uuid == CBUUID(string: BluetoothPointCommand.commandID) else { return }
        connectedPeers.insert(central.identifier)
        status = "请在 Mac 输入本机接收码以发送坐标。"
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard manager === peripheral, characteristic.uuid == CBUUID(string: BluetoothPointCommand.commandID) else { return }
        connectedPeers.remove(central.identifier)
        if connectedPeers.isEmpty { status = "Mac 已断开，正在等待连接。" }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard manager === peripheral, enabled else {
            peripheral.respond(to: first, withResult: .insufficientAuthorization); return
        }
        guard requests.count == 1, first.offset == 0,
              first.characteristic.uuid == CBUUID(string: BluetoothPointCommand.commandID),
              let value = first.value else {
            peripheral.respond(to: first, withResult: .invalidAttributeValueLength); return
        }
        do {
            try receive(value, from: first.central.identifier)
            peripheral.respond(to: first, withResult: .success)
        } catch BluetoothPointCommand.Failure.code {
            peripheral.respond(to: first, withResult: .insufficientAuthorization)
        } catch {
            peripheral.respond(to: first, withResult: .invalidAttributeValueLength)
        }
    }
}
