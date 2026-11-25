import Foundation
import Network
import RemoteControl
@testable import MobileConnectionModel
import XCTest

/// 使用手机应用的生产连接模型，在本机回环接口验证两种 TLS 角色及跨传输的本机绑定。
@MainActor
final class MobileConnectionTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw RemoteError("等待连接状态超时。")
    }

    func testUSBGrantThenManualWiFi() async throws {
        let key = try RemotePairing.generate()
        let grant = DeviceGrant(device: "test-phone", token: try RemotePairing.generate())
        let target = RemoteTarget(id: grant.device, session: UUID(), available: true, needsClear: false, detail: "test")
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var keys = [String: String]()
        let phone = MobileModel(loadKey: { keys[$0] }, storeKey: { keys[$1] = $0 }, preferences: defaults)
        defer { phone.disconnect() }
        let queue = DispatchQueue(label: "Everywhere.tests.mobile")
        phone.chooseTransport(.usb)
        phone.code = key
        phone.connect()
        try await waitUntil { phone.linkStatus.contains("已就绪") || !phone.usbListening }
        XCTAssertTrue(phone.usbListening, phone.linkStatus)
        let usb = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: RemotePairing.usbPort)!, using: try RemotePairing.parameters(key))
        let deadline = DispatchWorkItem { usb.cancel() }
        queue.asyncAfter(deadline: .now() + 12, execute: deadline)
        defer { deadline.cancel(); usb.cancel() }
        usb.start(queue: queue)
        let link = RemoteLink(usb)
        let status = try await link.receive(RemoteRequest.self)
        XCTAssertEqual(status.action, .status)
        try await link.send(RemoteReply(status, .status, "已绑定", targets: [target], boundDevice: target.id, grant: grant))
        try await waitUntil { phone.connected && phone.target?.id == target.id }
        phone.chooseTransport(.wifi)
        XCTAssertNil(phone.boundDevice)
        let settings = try RemotePairing.parameters(key)
        settings.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let wifi = try NWListener(using: settings)
        defer { wifi.cancel() }
        wifi.newConnectionHandler = { connection in
            connection.start(queue: queue)
            Task {
                do {
                    let channel = RemoteLink(connection)
                    let request = try await channel.receive(RemoteRequest.self)
                    XCTAssertEqual(request.grant, grant)
                    try await channel.send(RemoteReply(request, .status, "已验证", targets: [target], boundDevice: target.id))
                } catch { XCTFail(error.localizedDescription) }
            }
        }
        wifi.start(queue: queue)
        try await waitUntil { (wifi.port?.rawValue ?? 0) > 0 }
        phone.chooseHost(MobileModel.manual)
        phone.address = "127.0.0.1"
        phone.port = String(try XCTUnwrap(wifi.port).rawValue)
        phone.connectUsingUSBPairing()
        try await waitUntil { phone.connected && phone.target?.id == target.id }
        XCTAssertEqual(defaults.string(forKey: "mobile.mac.port"), phone.port)
    }
}
