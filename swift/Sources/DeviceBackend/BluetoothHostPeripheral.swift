import CoreBluetooth
import Foundation
import HostSession
import ScenarioKit

/// Mac 广播加密的指示特征，手机订阅后按设备接收命令并写回本次请求的结果。
@MainActor
package final class BluetoothHostPeripheral: NSObject, LocationBackend, @preconcurrency CBPeripheralManagerDelegate {
    package var onPeer: ((String, Bool) -> Void)?
    package var onStatus: ((String) -> Void)?
    package var codes: [String: String] = [:]
    package override init() { super.init() }
    package var onReady: (() -> Void)?
    package var onFailure: ((String) -> Void)?
    private var manager: CBPeripheralManager?
    private var outbound: CBMutableCharacteristic?
    private var rmcOutbound: CBMutableCharacteristic?
    private var peers: [String: CBCentral] = [:]
    private var pending: (device: String, nonce: Data, reply: CheckedContinuation<Void, Error>)?
    private var timeout: Task<Void, Never>?

    /// 显式开启一次广播，手机通过服务 UUID 发现这台 Mac。
    package func start() {
        guard manager == nil else { return }
        manager = CBPeripheralManager(delegate: self, queue: .main)
        onStatus?("正在准备 Mac 蓝牙广播…")
    }

    package func stop() {
        let old = manager
        manager = nil
        if old?.state == .poweredOn { old?.stopAdvertising(); old?.removeAllServices() }
        resetPeers()
    }

    private func resetPeers() {
        finish(.failure(DeviceConnectionLostError("蓝牙连接已结束。")))
        let ids = Array(peers.keys)
        peers.removeAll()
        codes.removeAll()
        outbound = nil
        rmcOutbound = nil
        for id in ids { onPeer?(id, false) }
    }

    package func set(_ point: GeoPoint, deviceID: String) async throws { try await send(point, to: deviceID) }
    package func clear(deviceID: String) async throws { try await send(nil, to: deviceID) }

    /// 每条指示携带独立四字节标识，最多等待 12 秒，仅接受目标手机的应用层回执。
    private func send(_ point: GeoPoint?, to id: String) async throws {
        try Task.checkCancellation()
        guard let peer = peers[id], let manager, let outbound, let code = codes[id], pending == nil else {
            throw BackendPreflightError("请先连接手机并输入本轮接收码。")
        }
        let nonce = Data((0..<4).map { _ in UInt8.random(in: .min ... .max) })
        let rmcField = rmcOutbound.flatMap { field in
            field.subscribedCentrals?.contains(where: { $0.identifier == peer.identifier }) == true ? field : nil
        }
        let field = rmcField ?? outbound
        let payload = try BluetoothPointCommand(point).payload(code: code)
        let packet = nonce + payload.data(supportsRMC: rmcField != nil, capacity: peer.maximumUpdateValueLength - nonce.count)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending = (id, nonce, continuation)
                guard manager.updateValue(packet, for: field, onSubscribedCentrals: [peer]) else {
                    finish(.failure(BackendPreflightError("蓝牙发送队列忙，请重试。")))
                    return
                }
                timeout = Task {
                    do { try await Task.sleep(for: .seconds(12)) } catch { return }
                    finish(.failure(DeviceConnectionLostError("未收到手机对本次坐标的回执。")))
                }
            }
        } onCancel: {
            Task { @MainActor in
                if self.pending?.nonce == nonce { self.finish(.failure(DeviceConnectionLostError("等待蓝牙回执已取消。"))) }
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        timeout?.cancel()
        timeout = nil
        let command = pending
        pending = nil
        command?.reply.resume(with: result)
    }

    package func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard manager === peripheral else { return }
        guard peripheral.state == .poweredOn else {
            resetPeers()
            if [.unauthorized, .unsupported, .poweredOff].contains(peripheral.state) {
                onFailure?("无法启动蓝牙广播，请检查蓝牙开关和系统权限。")
            }
            onStatus?(peripheral.state == .unauthorized ? "请在 Mac 设置中允许 Everywhere 使用蓝牙。" : "等待 Mac 蓝牙就绪。")
            return
        }
        let service = CBMutableService(type: CBUUID(string: BluetoothPointCommand.reverseServiceID), primary: true)
        let field = CBMutableCharacteristic(type: CBUUID(string: BluetoothPointCommand.commandID),
            properties: [.indicate, .indicateEncryptionRequired], value: nil, permissions: [])
        let ack = CBMutableCharacteristic(type: CBUUID(string: BluetoothPointCommand.receiptID),
            properties: [.write], value: nil, permissions: [.writeEncryptionRequired])
        let rmc = CBMutableCharacteristic(type: CBUUID(string: BluetoothPointCommand.rmcID),
            properties: [.indicate, .indicateEncryptionRequired], value: nil, permissions: [])
        outbound = field
        rmcOutbound = rmc
        service.characteristics = [field, rmc, ack]
        peripheral.add(service)
    }

    package func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard manager === peripheral else { return }
        if let error { stop(); onFailure?(error.localizedDescription); onStatus?(error.localizedDescription); return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service.uuid],
                                    CBAdvertisementDataLocalNameKey: ProcessInfo.processInfo.hostName])
    }

    package func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard manager === peripheral else { return }
        if let error { stop(); onFailure?(error.localizedDescription); onStatus?(error.localizedDescription) }
        else { onReady?(); onStatus?("Mac 正在广播，请在手机选择「手机扫描 Mac」。") }
    }

    package func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard manager === peripheral, (characteristic === outbound || characteristic === rmcOutbound) else { return }
        let id = central.identifier.uuidString
        peers[id] = central
        onPeer?(id, true)
    }

    package func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard manager === peripheral, (characteristic === outbound || characteristic === rmcOutbound) else { return }
        let id = central.identifier.uuidString
        let otherField = characteristic === outbound ? rmcOutbound : outbound
        if otherField?.subscribedCentrals?.contains(where: { $0.identifier == central.identifier }) == true { return }
        peers[id] = nil
        // 同一广播会话内允许同机短暂掉线后复用接收码，停止广播时统一撤销。
        if pending?.device == id { finish(.failure(DeviceConnectionLostError("手机已断开。"))) }
        onPeer?(id, false)
    }

    package func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard manager === peripheral, requests.count == 1, first.offset == 0, let packet = first.value,
              packet.count == 5, first.characteristic.uuid == CBUUID(string: BluetoothPointCommand.receiptID),
              let pending, pending.device == first.central.identifier.uuidString, pending.nonce == packet.prefix(4) else {
            peripheral.respond(to: first, withResult: .unlikelyError)
            return
        }
        peripheral.respond(to: first, withResult: .success)
        if packet.last == 0 { finish(.success(())) }
        else { finish(.failure(BackendPreflightError("手机拒绝了本次命令，请核对接收码。"))) }
    }
}
