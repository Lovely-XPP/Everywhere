import Foundation
import ScenarioKit
import XCTest
@testable import MacHost

/// 用本地进程替身验证从地图参数到认证、回执及停止会话的控制流。
@MainActor
final class IAP2LocationSessionTests: XCTestCase {
    /// 列表无变化时也要确认本次手动刷新；后台轮询保留最近一次结果。
    func testManualRefreshFeedbackSurvivesPolling() async {
        let session = IAP2LocationSession(pairedDevices: { ["AA:BB:CC:DD:EE:FF": "iPhone"] })
        await session.refresh(userInitiated: true)
        XCTAssertEqual(session.refreshFeedback, "共 1 台")
        await session.refresh(userInitiated: true)
        XCTAssertEqual(session.refreshFeedback, "列表无变化 · 共 1 台")
        let date = session.lastManualRefresh
        XCTAssertNotNil(date)
        await session.refresh()
        XCTAssertEqual(session.lastManualRefresh, date)
        XCTAssertFalse(session.refreshingByRequest)
    }

    /// 首次读取空清单时同样返回可见的完成状态。
    func testEmptyManualRefresh() async {
        let session = IAP2LocationSession(pairedDevices: { [:] })
        await session.refresh(userInitiated: true)
        XCTAssertEqual(session.refreshFeedback, "未找到已配对设备")
        XCTAssertNotNil(session.lastManualRefresh)
    }

    func testConnectionStartsWithoutCoordinates() throws {
        let helper = URL(fileURLWithPath: "/test/authorized helper")
        let address = "AA:BB:CC:DD:EE:FF"
        let bridge = URL(fileURLWithPath: "/test/Contents/Helpers/bluetooth-bridge")
        let args = ["--transport", "bluetooth", "--device", address, "--bluetooth-helper", bridge.path]
        XCTAssertEqual(IAP2LocationSession.arguments(address: address, bridge: bridge, helper: helper),
                       ["connect"] + args + ["--auth-helper", helper.path])
    }

    /// 新设备即使尚未出现在系统配对记录，也应按所选地址启动真实的探测进程入口。
    func testDiscoveryStartsAuthenticatedProbeForSelectedAddress() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let client = "AccessoryLocation.app/Contents/MacOS/accessory-location"
        let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" > args\n"
        for (path, body) in [(client, script), ("mfi-auth", "#!/bin/sh"), ("bluetooth-bridge", "#!/bin/sh")] {
            let file = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let session = IAP2LocationSession(helpers: folder, pairedDevices: { ["00:11:22:33:44:55": "iPhone"] })
        session.connectPhone(address: "aa-bb-cc-dd-ee-ff", name: "iPhone", helper: "")
        XCTAssertTrue(session.running)
        for _ in 0..<100 where session.running { try await Task.sleep(for: .milliseconds(20)) }
        let arguments = try String(contentsOf: folder.appendingPathComponent("args"), encoding: .utf8).components(separatedBy: .newlines)
        XCTAssertEqual(arguments.first, "connect")
        XCTAssertTrue(arguments.contains("AA:BB:CC:DD:EE:FF"))
        XCTAssertTrue(arguments.contains(folder.appendingPathComponent("mfi-auth").path))
        await session.refresh()
        XCTAssertEqual(session.address, "AA:BB:CC:DD:EE:FF")
        XCTAssertNotNil(session.devices[session.address])
    }

    func testRFCOMMFailureIncludesLiveChannelAndOSCode() {
        let result = IAP2LocationSession.failureMessage(type: "RuntimeError", detail: "EW_OPEN_ERROR channel=7 status=0xe00002d5 record=live cause=busy", stage: "正在建立会话")
        XCTAssertTrue(result.contains("通道 7"))
        XCTAssertTrue(result.contains("本次查询"))
        XCTAssertTrue(result.contains("0xe00002d5"))
        XCTAssertTrue(result.contains("正忙"))
    }

    func testFailureDescriptionsSeparateControllerAndAuthentication() {
        let controller = IAP2LocationSession.failureMessage(type: "RuntimeError", detail: "Unable to read the local Bluetooth controller address", stage: "正在建立会话")
        let credentials = IAP2LocationSession.failureMessage(type: "RuntimeError", detail: "Accessory authentication required; no credential configured", stage: "握手")
        let acl = IAP2LocationSession.failureMessage(type: "RuntimeError", detail: "EW_BASEBAND_ERROR status=0xe00002d6", stage: "")
        XCTAssertTrue(acl.contains("经典蓝牙链路未建立"))
        XCTAssertTrue(acl.contains("0xe00002d6"))
        XCTAssertTrue(controller.contains("Mac 蓝牙开关"))
        XCTAssertTrue(credentials.contains("配件认证"))
        XCTAssertFalse(controller.contains("认证"))
    }

    /// 断线清除旧回执。即使草稿坐标相同也能确认续发，旧连接的命令不能用于新连接。
    func testResumeSendsCurrentGeneration() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = """
        #!/bin/sh
        echo '{"event":"reconnecting","generation":1,"delay":2,"needs_confirmation":true}'
        echo '{"event":"identification_accepted"}'
        echo '{"event":"authentication_succeeded"}'
        echo '{"event":"reconnected","needs_confirmation":true}'
        IFS= read -r line || exit 1
        echo "$line" > resume.json
        echo '{"event":"target_updated"}'
        exec /bin/sleep 5
        """
        let files = [("AccessoryLocation.app/Contents/MacOS/accessory-location", script),
                     ("bluetooth-bridge", "#!/bin/sh"), ("mfi-auth", "#!/bin/sh")]
        for (path, body) in files {
            let file = folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let address = "AA:BB:CC:DD:EE:FF"
        let session = IAP2LocationSession(helpers: folder, pairedDevices: { [address: "测试设备"] })
        await session.refresh()
        session.address = address
        let point = try GeoPoint(latitude: 12.5, longitude: 30)
        session.start(helper: "")
        defer { session.stop() }
        for _ in 0..<100 where !session.needsResume || session.reconnecting { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(session.needsResume)
        XCTAssertNil(session.acknowledgedPoint)
        session.preparePointSend(point, jitter: true)?()
        for _ in 0..<100 where session.needsResume { try await Task.sleep(for: .milliseconds(25)) }
        let data = try Data(contentsOf: folder.appendingPathComponent("resume.json"))
        let request = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Double])
        XCTAssertEqual(request, ["latitude": 12.5, "longitude": 30, "generation": 1, "jitter": 1])
        XCTAssertFalse(session.needsResume)
        session.stop()
        for _ in 0..<100 where session.running { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertFalse(session.running)
    }

    func testBundledProviderEventsAndRelease() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = directory.appendingPathComponent("AccessoryLocation.app/Contents/MacOS/accessory-location")
        let bridge = directory.appendingPathComponent("bluetooth-bridge")
        let helper = directory.appendingPathComponent("mfi-auth")
        let sender = """
        #!/bin/sh
        while [ "$#" -gt 0 ] && [ "$1" != "--auth-helper" ]; do shift; done
        [ "$#" -ge 2 ] && [ "$2" -ef ./mfi-auth ] || exit 1
        echo '{"event":"identification_accepted"}'
        echo '{"event":"authentication_succeeded"}'
        echo '{"event":"location_requested"}'
        IFS= read -r line || exit 1
        echo '{"event":"location_link_acknowledged","count":1}'
        while IFS= read -r line; do :; done
        """
        for (file, body) in [(client, sender), (helper, "#!/bin/sh\nexit 0"), (bridge, "#!/bin/sh\nexit 0")] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let session = IAP2LocationSession(helpers: directory, pairedDevices: { ["AA:BB:CC:DD:EE:FF": "测试设备"] })
        await session.refresh()
        session.address = "AA:BB:CC:DD:EE:FF"
        let point = try GeoPoint(latitude: 1, longitude: -2)
        XCTAssertNil(session.preparePointSend(point, jitter: false))
        session.start(helper: "")
        for _ in 0..<100 where !session.readyToSend { try await Task.sleep(for: .milliseconds(20)) }
        try XCTUnwrap(session.preparePointSend(point, jitter: false))()
        defer { session.stop() }
        for _ in 0..<100 where !session.status.contains("定位包已获链路确认") { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertTrue(session.running)
        let report = try JSONDecoder().decode(IAP2ConnectionReport.self, from: JSONEncoder().encode(session.phoneReport))
        XCTAssertTrue(report.authenticated)
        XCTAssertEqual(report.target, "测试设备")
        XCTAssertTrue(session.status.contains("定位包已获链路确认"), session.status)
        let restore = try XCTUnwrap(session.prepareRestore())
        restore()
        for _ in 0..<200 where session.running { try await Task.sleep(for: .milliseconds(30)) }
        XCTAssertFalse(session.phoneReport.authenticated)
        XCTAssertFalse(session.running)
        XCTAssertTrue(session.status.contains("配件位置输出已结束"), session.status)
        XCTAssertNil(session.requestedPoint)
        XCTAssertFalse(session.canRestore)
        restore()
        XCTAssertFalse(session.running)
    }
}
