import CoreBluetooth
import ScenarioKit

/// 广播发现信息，配对后的手机通过加密读取状态。单字节通知让手机重新读取最新快照。
@MainActor
package final class IAP2StatusPeripheral: NSObject, @preconcurrency CBPeripheralManagerDelegate {
    package override init() { super.init() }
    package var onReady: (() -> Void)?
    package var onFailure: ((String) -> Void)?
    private var manager: CBPeripheralManager?
    private var field: CBMutableCharacteristic?
    private var snapshot = Data()
    private var notifyPending = false
    private var longReads = [UUID: Data]()
    package var onError: ((String) -> Void)?

    package func setEnabled(_ enabled: Bool) {
        if enabled {
            if manager == nil { manager = CBPeripheralManager(delegate: self, queue: .main) }
        } else {
            if manager?.state == .poweredOn { manager?.stopAdvertising(); manager?.removeAllServices() }
            manager = nil
            resetField()
        }
    }

    private func resetField() {
        field = nil
        notifyPending = false
        longReads.removeAll()
    }

    package func update(_ report: IAP2ConnectionReport) {
        guard let data = try? JSONEncoder().encode(report), data != snapshot else { return }
        snapshot = data
        notify()
    }

    private func notify() {
        guard let manager, manager.state == .poweredOn, let field, field.subscribedCentrals?.isEmpty == false else { return }
        notifyPending = !manager.updateValue(Data([0]), for: field, onSubscribedCentrals: nil)
    }

    package func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        if manager === peripheral && notifyPending { notify() }
    }

    package func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard manager === peripheral else { return }
        resetField()
        guard peripheral.state == .poweredOn else {
            if peripheral.state == .unauthorized { onError?("请允许 Everywhere 使用 Mac 蓝牙，以便手机查看状态。") }
            return
        }
        let service = CBMutableService(type: CBUUID(string: IAP2ConnectionReport.serviceID), primary: true)
        let value = CBMutableCharacteristic(type: CBUUID(string: IAP2ConnectionReport.fieldID),
            properties: [.read, .notify, .notifyEncryptionRequired], value: nil, permissions: [.readEncryptionRequired])
        field = value
        service.characteristics = [value]
        peripheral.add(service)
    }

    package func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard manager === peripheral else { return }
        if let error { onError?(error.localizedDescription); return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service.uuid],
                                    CBAdvertisementDataLocalNameKey: ProcessInfo.processInfo.hostName])
    }

    package func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard manager === peripheral else { return }
        if let error { onError?(error.localizedDescription) } else { onReady?() }
    }

    package func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard manager === peripheral, request.characteristic.uuid == field?.uuid else {
            peripheral.respond(to: request, withResult: .attributeNotFound); return
        }
        let id = request.central.identifier
        if request.offset == 0 { longReads[id] = snapshot }
        guard let data = longReads[id], request.offset <= data.count else {
            peripheral.respond(to: request, withResult: .invalidOffset); return
        }
        request.value = data.dropFirst(request.offset)
        peripheral.respond(to: request, withResult: .success)
    }

    package func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        if manager === peripheral { longReads[central.identifier] = nil }
    }
}
