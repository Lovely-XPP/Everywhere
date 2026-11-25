import Foundation
@testable import DeviceBackend
import HostSession
import ScenarioKit
import XCTest

/// 用 CoreDevice 的列表和命令替身验证方向、目标与断线行为。
final class WirelessLocationTests: XCTestCase {
    private actor Tool {
        var transport = "localNetwork"
        var paired = true
        var supportsLocation = true
        func disableLocation() { supportsLocation = false }
        var version = "17.4"
        func report(_ version: String) { self.version = version }
        var writes: [[String]] = []
        func useCable() { transport = "wired" }
        func useWiFi() { transport = "localNetwork" }
        func unpair() { paired = false }
        func run(_ args: [String]) throws -> String {
            if args.first == "help" {
                if !supportsLocation { throw CocoaError(.featureUnsupported) }
                return ""
            }
            if args.first != "list" { writes.append(args); return "" }
            let device = ["connectionProperties": ["pairingState": paired ? "paired" : "unpaired", "transportType": transport],
                          "hardwareProperties": ["udid": "phone", "deviceType": "iPhone", "reality": "physical"],
                          "deviceProperties": ["name": "测试手机", "osVersionNumber": version]]
            let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": [device]]])
            return String(decoding: data, as: UTF8.self)
        }
    }

    private actor Legacy: LocationBackend {
        var devices: [String] = []
        func set(_ point: GeoPoint, deviceID: String) { devices.append(deviceID) }
        func clear(deviceID: String) { devices.append(deviceID) }
    }

    /// 自动 USB 的旧版和现代分支分别验证，断线、未知版本或无线目标均不得写入。
    func testWiredDispatchUsesObservedSystemAndTransport() async throws {
        let tool = Tool()
        let legacy = Legacy()
        let backend = CoreDeviceLocationBackend(transport: .usb, legacy: legacy) { try await tool.run($0) }
        let point = try GeoPoint(latitude: 2, longitude: -3)
        do { try await backend.set(point, deviceID: "phone"); XCTFail("不可取用 Wi-Fi 目标") }
        catch is DeviceConnectionLostError {}
        await tool.useCable()
        await tool.report("16.7.1")
        try await backend.set(point, deviceID: "phone")
        try await backend.clear(deviceID: "phone")
        await tool.report("17.4")
        try await backend.set(point, deviceID: "phone")
        try await backend.clear(deviceID: "phone")
        await tool.disableLocation()
        do { try await backend.set(point, deviceID: "phone"); XCTFail("不支持的工具必须在发送前拒绝") }
        catch is BackendPreflightError {}
        await tool.report("")
        do { try await backend.clear(deviceID: "phone"); XCTFail("版本未知不可写入") }
        catch is BackendPreflightError {}
        let old = await legacy.devices
        let modern = await tool.writes
        XCTAssertEqual(old, ["phone", "phone"])
        XCTAssertEqual(modern.map { $0[3] }, ["coordinate", "clear"])
    }

    /// 同时识别两种连接，按 UDID 合并重复行，并在拔线后重新按当前链路执行。
    func testAutomaticDiscoveryAndTransportChange() async throws {
        func record(_ id: String, _ transport: String) -> [String: [String: String]] {
            ["connectionProperties": ["pairingState": "paired", "transportType": transport],
             "hardwareProperties": ["udid": id, "deviceType": "iPhone", "reality": "physical"],
             "deviceProperties": ["name": "iPhone", "osVersionNumber": "17.4"]]
        }
        for transports in [["wired", "localNetwork"], ["localNetwork", "wired"]] {
            let records = transports.map { record("first", $0) } + [record("second", "localNetwork"), record("third", "unknown")]
            let data = try JSONSerialization.data(withJSONObject: ["result": ["devices": records]])
            let backend = CoreDeviceLocationBackend(transport: nil) { _ in String(decoding: data, as: UTF8.self) }
            let devices = try await backend.devices()
            XCTAssertEqual(devices.map(\.id), ["first", "second"])
            XCTAssertEqual(devices.map(\.transport), [.usb, .wifi])
        }

        let tool = Tool()
        let legacy = Legacy()
        let backend = CoreDeviceLocationBackend(transport: nil, legacy: legacy) { try await tool.run($0) }
        await tool.useCable()
        await tool.report("16.7")
        try await backend.set(try GeoPoint(latitude: 10, longitude: 20), deviceID: "phone")
        await tool.useWiFi()
        try await backend.clear(deviceID: "phone")
        let usbWrites = await legacy.devices
        let wifiWrites = await tool.writes
        XCTAssertEqual(usbWrites, ["phone"])
        XCTAssertEqual(wifiWrites, [["device", "simulate", "location", "clear", "--device", "phone", "--timeout", "30"]])
    }

    /// IP 查验必须读到选定真机的在线状态，且拒绝不匹配或已改走 USB 的目标。
    func testWirelessAddressVerificationUsesLivePairedDevice() async throws {
        let tool = Tool()
        let backend = WirelessLocationBackend { try await tool.run($0) }
        let device = try await backend.verifyWirelessDevice(id: "PHONE")
        XCTAssertEqual(device.id, "phone")
        do { _ = try await backend.verifyWirelessDevice(id: "other"); XCTFail("不应替换目标") }
        catch is BackendPreflightError {}
        await tool.useCable()
        do { _ = try await backend.verifyWirelessDevice(id: "phone"); XCTFail("不应回退 USB") }
        catch is BackendPreflightError {}
        let requests = await tool.writes
        XCTAssertEqual(requests, [["device", "info", "lockState", "--device", "phone", "--quiet", "--timeout", "8"]])
    }

    func testWirelessCommandsStayBoundToPairedTarget() async throws {
        let tool = Tool()
        let backend = WirelessLocationBackend { try await tool.run($0) }
        let initial = try await backend.devices()
        XCTAssertEqual(initial.first?.name, "测试手机")
        try await backend.set(try GeoPoint(latitude: -12, longitude: -70), deviceID: "phone")
        try await backend.clear(deviceID: "phone")
        await tool.useCable()
        do { try await backend.clear(deviceID: "phone"); XCTFail("禁止回退到有线设备") }
        catch is DeviceConnectionLostError {}
        let writes = await tool.writes
        XCTAssertEqual(writes, [
            ["device", "simulate", "location", "coordinate", "--latitude=-12.0", "--longitude=-70.0", "--device", "phone", "--timeout", "30"],
            ["device", "simulate", "location", "clear", "--device", "phone", "--timeout", "30"]
        ])
        let unpaired = Tool()
        await unpaired.unpair()
        let hidden = try await WirelessLocationBackend { try await unpaired.run($0) }.devices()
        XCTAssertTrue(hidden.isEmpty)
    }
}
