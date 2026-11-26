import DeviceBackend
import Foundation
import ScenarioKit

/// Qt 宿主使用一条本地标准输入管道控制一个 CoreBluetooth 会话。
private func emit(_ value: Any) {
    guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
    FileHandle.standardOutput.write(data + Data([10]))
}

@MainActor
private func serve() async throws {
    let args = Array(CommandLine.arguments.dropFirst())
    let central = BluetoothLocationBackend()
    let reverse = BluetoothHostPeripheral()
    let status = IAP2StatusPeripheral()
    let mode = args.first ?? ""
    var peers = Set<String>()
    switch mode {
    case "--self-test":
        emit(["ready": true])
        return
    case "scan":
        emit(["devices": try await central.devices().map { ["id": $0.id, "name": $0.name] }])
        return
    case "central" where args.count == 2:
        try await central.connect(args[1]) { exit(1) }
        emit(["ready": true])
    case "markers":
        reverse.onPeer = { id, online in
            if online { peers.insert(id) } else { peers.remove(id) }
        }
        reverse.onReady = { emit(["ready": true]) }
        reverse.onFailure = { emit(["error": $0]); exit(1) }
        reverse.start()
    case "status":
        status.onReady = { emit(["ready": true]) }
        status.onError = { emit(["error": $0]); exit(1) }
        status.setEnabled(true)
    default:
        throw CocoaError(.fileReadUnsupportedScheme)
    }
    // stdin 在后台读取；蓝牙对象及命令始终在主 actor 上串行执行。
    while let line = await Task.detached(operation: { readLine() }).value {
        do {
            let raw = Data(line.utf8)
            guard let request = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            switch (mode, request["op"] as? String) {
            case ("markers", "peers"):
                emit(["peers": Array(peers).sorted()])
            case ("status", "status"):
                status.update(try JSONDecoder().decode(IAP2ConnectionReport.self, from: raw))
                emit(["ok": true])
            case ("central", "marker"), ("markers", "marker"):
                guard let id = request["id"] as? String, let code = request["code"] as? String,
                      mode == "central" ? id == args[1] : peers.contains(id) else {
                    throw CocoaError(.fileReadUnknown)
                }
                if mode == "central" { central.setCode(code, for: id) } else { reverse.codes[id] = code }
                if request["coords"] is NSNull {
                    if mode == "central" { try await central.clear(deviceID: id) } else { try await reverse.clear(deviceID: id) }
                } else {
                    guard let coords = request["coords"] as? [Double], coords.count == 2 else { throw CocoaError(.fileReadCorruptFile) }
                    let point = try GeoPoint(latitude: coords[0], longitude: coords[1])
                    if mode == "central" { try await central.set(point, deviceID: id) } else { try await reverse.set(point, deviceID: id) }
                }
                emit(["ok": true])
            default: throw CocoaError(.fileReadCorruptFile)
            }
        } catch { emit(["error": error.localizedDescription]) }
    }
}

Task { @MainActor in
    do { try await serve(); exit(0) }
    catch { emit(["error": error.localizedDescription]); exit(1) }
}
dispatchMain()
