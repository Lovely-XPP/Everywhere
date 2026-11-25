import Foundation
import HostSession
import ScenarioKit
@testable import MacHost
import Network
import RemoteControl
import XCTest

/// 在明确指定的 TCP 端口上实际握手，不依赖 Bonjour 或用户钥匙串。
@MainActor
final class NetworkListenerTests: XCTestCase {
    func testPortParsing() {
        XCTAssertEqual(RemotePairing.parsePort(" 49372 "), 49372)
        XCTAssertEqual(RemotePairing.parsePort("65535"), 65535)
        for invalid in ["", "0", "-1", "+80", "65536", "8.0"] {
            XCTAssertNil(RemotePairing.parsePort(invalid))
        }
    }

    func testManualTCPWithPairing() async throws {
        let model = MacConsoleModel()
        let host = RemoteHost()
        let key = try RemotePairing.generate()
        let port = NWEndpoint.Port(rawValue: UInt16.random(in: 52000...60000))!
        try host.listen(model, secret: key, port: port, advertise: false)
        defer { host.stopWiFi() }
        for _ in 0..<100 where host.enabled && !host.message.contains("TLS") {
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTAssertTrue(host.enabled, host.message)
        let request = RemoteRequest(.status)
        let reply = try await requestStatus(request, port: port, key: key)
        XCTAssertEqual(reply.id, request.id)
        XCTAssertEqual(reply.phase, .status)
        do {
            _ = try await requestStatus(request, port: port, key: RemotePairing.generate())
            XCTFail("不同配对码仍获取了设备状态")
        } catch {}
    }

    /// 两台可用真机同时在线时，网络连接只能看到和写入 USB 曾绑定的那一台。
    func testOnlyBoundPhoneCanChangeItself() async throws {
        actor Recorder: LocationBackend {
            var devices: [String] = []
            func set(_ point: GeoPoint, deviceID: String) async throws { devices.append(deviceID) }
            func clear(deviceID: String) async throws { devices.append(deviceID) }
        }
        var vault: [String: String] = [:]
        let identity = HostPairingIdentity(load: { vault[$0] }, save: { vault[$1] = $0 })
        let key = try RemotePairing.generate()
        let grant = try await identity.grant(forUSB: "ab-cd", hostKey: key)
        let forged = DeviceGrant(device: "OTHER", token: grant.token)
        let invalid = try await identity.verify(forged, hostKey: key)
        XCTAssertNil(invalid)
        let wrongHost = try await identity.verify(grant, hostKey: RemotePairing.generate())
        XCTAssertNil(wrongHost)

        let backend = Recorder()
        let model = MacConsoleModel()
        model.registerTarget("ABCD", backend: backend)
        model.registerTarget("OTHER", backend: backend)
        let host = RemoteHost(identity: identity)
        let port = NWEndpoint.Port(rawValue: UInt16.random(in: 52000...60000))!
        try host.listen(model, secret: key, port: port, advertise: false)
        defer { host.stopWiFi() }
        for _ in 0..<100 where !host.message.contains("TLS") { try await Task.sleep(for: .milliseconds(30)) }
        let unbound = try await requestStatus(RemoteRequest(.status), port: port, key: key)
        XCTAssertNil(unbound.boundDevice)
        XCTAssertTrue(unbound.targets.isEmpty)
        let connection = NWConnection(host: "127.0.0.1", port: port, using: try RemotePairing.parameters(key))
        let queue = DispatchQueue(label: "VirtualLocation.tests.self")
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + 6, execute: timeout)
        defer { timeout.cancel(); connection.cancel() }
        let link = RemoteLink(connection)
        try await link.send(RemoteRequest(.status, grant: grant))
        let state = try await link.receive(RemoteReply.self)
        XCTAssertEqual(state.boundDevice, "ABCD")
        XCTAssertEqual(state.targets.map(\.id), ["ABCD"])
        let other = try XCTUnwrap(model.remoteTargets.first { $0.id == "OTHER" })
        for target in [other, try XCTUnwrap(state.targets.first)] {
            try await link.send(RemoteRequest(.apply, target: target, latitude: 23, longitude: 113))
            _ = try await link.receive(RemoteReply.self)
            let result = try await link.receive(RemoteReply.self)
            XCTAssertEqual(result.phase, target.id == "OTHER" ? .rejected : .accepted)
        }
        let writes = await backend.devices
        XCTAssertEqual(writes, ["ABCD"])
    }

    private func requestStatus(_ request: RemoteRequest, port: NWEndpoint.Port, key: String) async throws -> RemoteReply {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: try RemotePairing.parameters(key))
        let queue = DispatchQueue(label: "VirtualLocation.tests.tcp")
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + 4, execute: timeout)
        defer { timeout.cancel(); connection.cancel() }
        connection.start(queue: queue)
        let link = RemoteLink(connection)
        try await link.send(request)
        return try await link.receive(RemoteReply.self)
    }
}
