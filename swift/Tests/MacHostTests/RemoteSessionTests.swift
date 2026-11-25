import HostSession
@testable import MacHost
import RemoteControl
import ScenarioKit
import XCTest

/// 使用内存后端检验手机与桌面共享的设备会话，不访问真机或钥匙串。
@MainActor
final class RemoteSessionTests: XCTestCase {
    private actor Recorder: LocationBackend {
        var writes: [GeoPoint?] = []
        func set(_ point: GeoPoint, deviceID: String) async throws { writes.append(point) }
        func clear(deviceID: String) async throws { writes.append(nil) }
    }

    /// 恢复确认只对原会话生效，成功回执包含对应执行路径的后续提示。
    func testRecoveryRequiresCurrentSessionAndReportsScope() async throws {
        for mode in [ConsoleBackendMode.automatic, .wired, .wireless, .bluetooth, .reverseBluetooth, .simulator] {
            let model = MacConsoleModel()
            let backend = Recorder()
            model.changeBackendMode(mode)
            model.registerTarget("test", backend: backend)
            model.selectedDeviceID = "test"
            if mode.isBluetooth {
                model.bluetoothCode = "123456"
                let unconnected = try XCTUnwrap(model.remoteTargets.first)
                let denied = await model.handleRemote(RemoteRequest(.apply, target: unconnected, latitude: 12, longitude: 34))
                XCTAssertEqual(denied.phase, .rejected)
                model.updateBluetoothConnection(true, for: "test")
            }
            let initial = try XCTUnwrap(model.remoteTargets.first)
            let apply = RemoteRequest(.apply, target: initial, latitude: 12, longitude: 34)
            let reply = await model.handleRemote(apply)
            XCTAssertEqual(reply.phase, .accepted)
            await model.restore(initial)
            let active = try XCTUnwrap(model.remoteTargets.first)
            XCTAssertEqual(active.hasActiveLocation, true)
            XCTAssertEqual(active.recoveryScope, mode.recoveryScope)
            await model.restore(active)
            let writes = await backend.writes
            XCTAssertEqual(writes, [try GeoPoint(latitude: 12, longitude: 34), nil])
            XCTAssertEqual(model.selectedDevice?.feedback, mode.recoveryScope.receipt)
            XCTAssertEqual(model.remoteTargets.first?.hasActiveLocation, false)
        }
    }

    /// 一次提交只执行一次，旧停止不能影响改点后的会话，手机命令不改变 Mac 的草稿或选择。
    func testRemoteReplayChangeAndClear() async throws {
        let model = MacConsoleModel()
        let backend = Recorder()
        model.registerTarget("test", backend: backend)
        let ledger = RemoteLedger()
        let first = try XCTUnwrap(model.remoteTargets.first)
        let set = RemoteRequest(.apply, target: first, latitude: 23, longitude: 113)
        let receipt = await ledger.perform(set, model: model)
        let repeated = await ledger.perform(set, model: model)
        XCTAssertEqual(receipt.phase, .accepted)
        XCTAssertEqual(repeated.targets.first?.session, receipt.targets.first?.session)
        let old = try XCTUnwrap(receipt.targets.first)
        let receipt2 = await ledger.perform(RemoteRequest(.apply, target: old, latitude: -33, longitude: 151), model: model)
        let rejected = await ledger.perform(RemoteRequest(.clear, target: old), model: model)
        XCTAssertEqual(receipt2.phase, .accepted)
        XCTAssertEqual(rejected.phase, .rejected)
        let clear = await ledger.perform(RemoteRequest(.clear, target: receipt2.targets.first), model: model)
        XCTAssertEqual(clear.phase, .accepted)
        let writes = await backend.writes
        XCTAssertEqual(writes, [try GeoPoint(latitude: 23, longitude: 113), try GeoPoint(latitude: -33, longitude: 151), nil])
        XCTAssertNil(model.selectedDeviceID)
        XCTAssertNil(model.draftPoint)
    }

    /// 过期、无效坐标、复用请求 ID 及目标失联均不会执行新的位置命令。
    func testInvalidRemoteCommandsHaveNoSideEffects() async throws {
        let model = MacConsoleModel()
        let backend = Recorder()
        model.registerTarget("test", backend: backend)
        let target = try XCTUnwrap(model.remoteTargets.first)
        let ledger = RemoteLedger()
        let bad = RemoteRequest(.apply, target: target, latitude: 91, longitude: 0)
        let conflict = RemoteRequest(.clear, target: target, id: bad.id)
        let expired = RemoteRequest(.clear, target: target, expires: Date().addingTimeInterval(-1))
        for request in [bad, conflict, expired] {
            let reply = await ledger.perform(request, model: model)
            XCTAssertEqual(reply.phase, .rejected)
        }
        await model.invalidateConnectionsForSleep()
        let afterSleep = await ledger.perform(RemoteRequest(.clear, target: target), model: model)
        XCTAssertEqual(afterSleep.phase, .rejected)
        let writes = await backend.writes
        XCTAssertTrue(writes.isEmpty)
    }
    /// USB 只显示所连设备，复用 Wi-Fi 请求的回执也必须核对目标归属。
    func testUSBBindingBeforeReplay() async throws {
        let model = MacConsoleModel()
        let backend = Recorder()
        model.registerTarget("a", backend: backend)
        model.registerTarget("b", backend: backend)
        let ledger = RemoteLedger()
        let status = await ledger.perform(RemoteRequest(.status), model: model, boundTo: "a")
        XCTAssertEqual(status.targets.map(\.id), ["a"])
        let second = try XCTUnwrap(model.remoteTargets.first { $0.id == "b" })
        let request = RemoteRequest(.apply, target: second, latitude: 5, longitude: 10)
        let wifi = await ledger.perform(request, model: model)
        let wrong = await ledger.perform(request, model: model, boundTo: "a")
        let repeated = await ledger.perform(request, model: model, boundTo: "b")
        XCTAssertEqual(wifi.phase, .accepted)
        XCTAssertEqual(wrong.phase, .rejected)
        XCTAssertTrue(wrong.targets.isEmpty)
        XCTAssertEqual(repeated.targets.map(\.id), ["b"])
        let writes = await backend.writes
        XCTAssertEqual(writes.count, 1)
    }

    /// 拔线后保留清除门禁。同一手机恢复不会重放旧点，休眠仍需要重新确认目标。
    func testUSBReconnectNeedsExplicitClear() async throws {
        let model = MacConsoleModel()
        model.changeBackendMode(.wired)
        let backend = Recorder()
        model.registerTarget("a", backend: backend)
        let ledger = RemoteLedger()
        let request = RemoteRequest(.apply, target: model.remoteTargets.first, latitude: 5, longitude: 10)
        let receipt = await ledger.perform(request, model: model, boundTo: "a")
        XCTAssertEqual(receipt.phase, .accepted)
        await model.usbCableLost("a")
        XCTAssertFalse(try XCTUnwrap(model.remoteTargets.first).available)
        model.confirmUSBController("a")
        let state = try XCTUnwrap(model.remoteTargets.first)
        XCTAssertTrue(state.available)
        XCTAssertTrue(state.needsClear)
        let clear = await ledger.perform(RemoteRequest(.clear, target: state), model: model, boundTo: "a")
        XCTAssertEqual(clear.phase, .accepted)
        let writes = await backend.writes
        XCTAssertEqual(writes, [try GeoPoint(latitude: 5, longitude: 10), nil])
        await model.invalidateConnectionsForSleep()
        model.confirmUSBController("a")
        XCTAssertFalse(try XCTUnwrap(model.remoteTargets.first).available)
    }

}
