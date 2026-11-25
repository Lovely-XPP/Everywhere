import CoreBluetooth
import Foundation
import HostSession
import ScenarioKit

/// 由同一 Mac 上的 CoreBluetooth 分配标识，和 USB UDID 分开使用。
public struct BluetoothTarget: Sendable {
    public let id: String
    public let name: String
    /// 扫描结束时，系统是否报告与此接收服务已有 BLE 连接。
    public let systemConnected: Bool

    /// 合并附近广播与系统连接快照，同一设备只保留一条记录。
    static func merge(advertised: [UUID: String], connected: [UUID: String]) -> [Self] {
        advertised.merging(connected) { name, _ in name }.map { id, name in
            Self(id: id.uuidString, name: name, systemConnected: connected[id] != nil)
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}

/// 通过自有 GATT 服务向手机应用发送定位命令；复用显式连接，独立限制每条命令的等待时间。
@MainActor
public final class BluetoothLocationBackend: LocationBackend {
    private var codes: [String: String] = [:]

    private var links: [String: BluetoothOperation] = [:]

    /// 连接并核对手机暴露的写入特征；在手动断开或系统掉线前保留同一通道。
    public func connect(_ id: String, disconnected: @escaping @MainActor () -> Void) async throws {
        guard let uuid = UUID(uuidString: id) else { throw BackendPreflightError("蓝牙设备标识无效。") }
        if let link = links[id] {
            guard link.isReady else { throw BackendPreflightError("正在建立蓝牙连接。") }
            return
        }
        let link = BluetoothOperation()
        links[id] = link
        link.onClosed = { [weak self, weak link] in
            guard let self, let link, self.links[id] === link else { return }
            self.links[id] = nil
            disconnected()
        }
        do {
            _ = try await link.execute(.connect(uuid))
            guard links[id] === link, link.isReady else { throw BackendPreflightError("蓝牙连接已结束，请重新扫描。") }
        } catch {
            if links[id] === link { disconnect(id) }
            throw error
        }
    }

    /// 仅释放控制台所持连接，不向手机写入位置。
    public func disconnect(_ id: String) { links.removeValue(forKey: id)?.close() }

    public func disconnectAll() {
        for id in Array(links.keys) { disconnect(id) }
    }

    private let write: (@MainActor (UUID, BluetoothPointCommand.Payload) async throws -> Void)?

    public init() {
        write = nil
    }

    /// 测试时替换无线传输，其余接收码、目标标识和命令编码走生产路径。
    init(write: @escaping @MainActor (UUID, BluetoothPointCommand.Payload) async throws -> Void) { self.write = write }
    public func code(for id: String) -> String { codes[id] ?? "" }
    public func setCode(_ code: String, for id: String) { codes[id] = code }
    public func forgetCodes() { codes.removeAll() }

    /// 限时发现正在广播本应用接收服务的设备。
    public func devices() async throws -> [BluetoothTarget] {
        try await BluetoothOperation().execute(.scan)
    }

    /// 等待手机完成坐标更新后发出的带响应写入回执。
    public func set(_ point: GeoPoint, deviceID: String) async throws { try await send(point, to: deviceID) }

    public func clear(deviceID: String) async throws { try await send(nil, to: deviceID) }

    private func send(_ point: GeoPoint?, to id: String) async throws {
        guard let uuid = UUID(uuidString: id), let code = codes[id], BluetoothPointCommand.validCode(code) else {
            throw BackendPreflightError("请输入目标手机显示的六位蓝牙接收码。")
        }
        let data = try BluetoothPointCommand(point).payload(code: code)
        if let link = links[id] { try await link.writeConnected(data) }
        else if let write { try await write(uuid, data) }
        else if point == nil { _ = try await BluetoothOperation().execute(.write(uuid, data)) }
        else { throw BackendPreflightError("请先连接手机的蓝牙接收服务。") }
    }
}

/// CoreBluetooth 在主队列报告连接变化；显式连接复用已发现的特征，每次只等待一条命令的回执。
@MainActor
private final class BluetoothOperation: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    enum Operation { case scan, connect(UUID), write(UUID, BluetoothPointCommand.Payload) }
    var onClosed: (@MainActor () -> Void)?
    private var readyField: CBCharacteristic?
    private let service = CBUUID(string: BluetoothPointCommand.serviceID)
    private let command = CBUUID(string: BluetoothPointCommand.commandID)
    private let rmc = CBUUID(string: BluetoothPointCommand.rmcID)
    private var supportsRMC = false

    /// 选用可容纳在一个 ATT 包内的表示，避免接收端处理部分写入。
    private func packet(_ payload: BluetoothPointCommand.Payload, for peer: CBPeripheral) -> Data {
        payload.data(supportsRMC: supportsRMC, capacity: peer.maximumWriteValueLength(for: .withoutResponse))
    }
    var isReady: Bool { readyField != nil && peer?.state == .connected }
    private var writeToken: UUID?
    private var operation = Operation.scan
    private var central: CBCentralManager?
    private var peer: CBPeripheral?
    private var pending: CheckedContinuation<[BluetoothTarget], Error>?
    private var timer: Task<Void, Never>?
    private var found: [UUID: String] = [:]
    private var started = false
    private var wrote = false

    func execute(_ operation: Operation) async throws -> [BluetoothTarget] {
        try Task.checkCancellation()
        guard Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") != nil else {
            throw BackendPreflightError("请打开打包的 Mac 控制台，以便 macOS 请求蓝牙权限。")
        }
        self.operation = operation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                central = CBCentralManager(delegate: self, queue: .main)
                schedule(seconds: 35) { self.fail("等待蓝牙连接或手机回执超时。") }
            }
        } onCancel: {
            Task { @MainActor in self.fail("蓝牙操作已取消。") }
        }
    }

    private func schedule(seconds: Int, action: @escaping @MainActor () -> Void) {
        timer?.cancel()
        timer = Task {
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            action()
        }
    }

    /// 使用已验证的写入特征；不重新建立连接或再次发现服务。
    func writeConnected(_ data: BluetoothPointCommand.Payload) async throws {
        try Task.checkCancellation()
        guard pending == nil, let peer, peer.state == .connected, let readyField else {
            throw BackendPreflightError("蓝牙通道尚未就绪，请重新连接。")
        }
        let token = UUID()
        writeToken = token
        let _: [BluetoothTarget] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                schedule(seconds: 35) { self.fail("等待手机蓝牙回执超时。") }
                wrote = true
                peer.writeValue(packet(data, for: peer), for: readyField, type: .withResponse)
            }
        } onCancel: {
            Task { @MainActor in
                if self.writeToken == token { self.fail("蓝牙写入已取消。") }
            }
        }
    }

    private func resolve(_ result: Result<[BluetoothTarget], Error>) {
        let continuation = pending
        pending = nil
        writeToken = nil
        timer?.cancel()
        timer = nil
        wrote = false
        continuation?.resume(with: result)
    }

    private func finish(_ result: Result<[BluetoothTarget], Error>) {
        let wasReady = readyField != nil
        readyField = nil
        peer?.delegate = nil
        central?.delegate = nil
        if let central, central.state == .poweredOn {
            if central.isScanning { central.stopScan() }
            if let peer { central.cancelPeripheralConnection(peer) }
        }
        peer = nil
        central = nil
        resolve(result)
        if wasReady { onClosed?() }
    }

    func close() { fail("控制台已释放蓝牙连接。") }

    private func fail(_ message: String) {
        if wrote { finish(.failure(DeviceConnectionLostError(message))) }
        else { finish(.failure(BackendPreflightError(message))) }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard pending != nil || readyField != nil else { return }
        switch central.state {
        case .unknown, .resetting:
            if started { fail("蓝牙连接已重置。") }
            return
        case .poweredOn: break
        case .unauthorized: fail("请在隐私与安全性中允许控制台使用蓝牙。"); return
        default: fail("Mac 蓝牙不可用，请检查蓝牙开关。"); return
        }
        guard !started else { return }
        started = true
        switch operation {
        case .scan:
            central.scanForPeripherals(withServices: [service])
            schedule(seconds: 5) {
                let peers = central.retrieveConnectedPeripherals(withServices: [self.service])
                var connected: [UUID: String] = [:]
                for peer in peers { connected[peer.identifier] = peer.name ?? "蓝牙设备" }
                self.finish(.success(BluetoothTarget.merge(advertised: self.found, connected: connected)))
            }
        case .connect(let id), .write(let id, _):
            guard let device = central.retrievePeripherals(withIdentifiers: [id]).first else {
                fail("无法找到所选手机，请重新刷新蓝牙设备。"); return
            }
            peer = device
            device.delegate = self
            central.connect(device)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        found[peripheral.identifier] = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "蓝牙设备"
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        fail(error?.localizedDescription ?? "未能连接目标手机。")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        fail("目标手机的蓝牙连接已断开。")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let target = peripheral.services?.first(where: { $0.uuid == service }) else {
            fail("手机未提供定位接收服务，请在手机上开启蓝牙接收。"); return
        }
        peripheral.discoverCharacteristics([command, rmc], for: target)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard pending != nil, !wrote, error == nil,
              let field = service.characteristics?.first(where: { $0.uuid == command && $0.properties.contains(.write) }) else {
            fail("手机未提供带回执的定位写入通道。"); return
        }
        supportsRMC = service.characteristics?.contains(where: { $0.uuid == rmc }) == true
        switch operation {
        case .connect:
            if field.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: field)
            } else {
                // 旧版手机只有写入通道，沿用原有连接行为。
                readyField = field
                resolve(.success([]))
            }
        case .write(_, let data):
            wrote = true
            peripheral.writeValue(packet(data, for: peripheral), for: field, type: .withResponse)
        case .scan: break
        }
    }

    /// 手机已观察到订阅后，控制台才把新版接收服务标为就绪。
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor field: CBCharacteristic, error: Error?) {
        guard peer === peripheral, field.uuid == command, case .connect = operation else { return }
        guard error == nil, field.isNotifying else { fail("手机蓝牙状态订阅已断开，请重新连接。"); return }
        guard readyField == nil, pending != nil else { return }
        readyField = field
        resolve(.success([]))
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        if invalidatedServices.contains(where: { $0.uuid == service }) { fail("手机已关闭或重置蓝牙接收服务。") }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard wrote, characteristic.uuid == command else { return }
        if let error = error as NSError? {
            if error.domain == CBATTErrorDomain && error.code == CBATTError.insufficientAuthorization.rawValue {
                let refusal = BackendPreflightError("手机拒绝写入，请核对接收码和本轮接收的 Mac。")
                if readyField != nil { resolve(.failure(refusal)) } else { finish(.failure(refusal)) }
            } else { fail(error.localizedDescription) }
        } else if readyField != nil { resolve(.success([])) }
        else { finish(.success([])) }
    }
}
