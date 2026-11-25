import CoreLocation
@testable import DeviceBackend
import Foundation
import HostSession
@testable import MacHost
import ScenarioKit
import XCTest

/// 直接验证主 actor 中控制台模型的草稿与设备选择，不发现或操作实际 USB 设备。
final class MacConsoleModelTests: XCTestCase {
    private let firstID = "00008030-001122334455aabb"
    private let secondID = "0123456789abcdef0123456789abcdef01234567"

    /// 同名真机可分别选择，刷新时保留原目标，会话随同一 UDID 更换链路。
    @MainActor
    func testDirectSelectionAcrossUSBAndWiFi() async throws {
        actor Devices {
            var links = ["phone-a": "wired", "phone-b": "localNetwork"]
            func unplug() { links = ["PHONE-A": "localNetwork", "phone-b": "localNetwork"] }
            func listing() throws -> String {
                let rows = links.map { id, link in
                    ["hardwareProperties": ["udid": id, "reality": "physical", "deviceType": "iPhone"],
                     "connectionProperties": ["pairingState": "paired", "transportType": link],
                     "deviceProperties": ["name": "iPhone"]]
                }
                return String(decoding: try JSONSerialization.data(withJSONObject: ["result": ["devices": rows]]), as: UTF8.self)
            }
        }
        let source = Devices()
        let model = MacConsoleModel(automaticBackend: CoreDeviceLocationBackend(transport: nil) { _ in try await source.listing() })
        await model.refreshDevices()
        XCTAssertNil(model.selectedDeviceID)
        XCTAssertEqual(model.deviceIDs, ["phone-a", "phone-b"])
        model.selectedDeviceID = "phone-a"
        let session = try XCTUnwrap(model.selectedDevice).sessionVersion
        XCTAssertEqual(model.selectedDevice?.transportLabel, "USB")
        await source.unplug()
        await model.refreshDevices()
        XCTAssertEqual(model.selectedDevice?.transportLabel, "Wi-Fi")
        XCTAssertEqual(model.selectedDevice?.sessionVersion, session)
        XCTAssertEqual(model.deviceIDs, ["phone-a", "phone-b"])
        await model.usbCableLost("phone-a")
        XCTAssertTrue(try XCTUnwrap(model.selectedDevice).isAvailable)
    }

    /// 广播发现、系统连接和通过服务核验的本应用连接显示为不同状态。
    func testBluetoothListLabelsReflectConnectionScope() {
        var device = DeviceSnapshot()
        XCTAssertEqual(device.bluetoothLabel, "连接待确认")
        device.isAvailable = true
        device.systemBluetoothConnected = false
        XCTAssertEqual(device.bluetoothLabel, "已发现 · 控制台未连接")
        device.systemBluetoothConnected = true
        XCTAssertEqual(device.bluetoothLabel, "系统已连接 · 控制台未连接")
        device.bluetoothConnected = true
        XCTAssertEqual(device.bluetoothLabel, "控制台已连接")
    }

    /// 空草稿不提前显示错误，完整文本统一解析成 WGS 84 坐标。
    @MainActor
    func testDraftUsesSharedCoordinateValidation() async throws {
        let model = MacConsoleModel()
        XCTAssertNil(model.draftPoint)
        XCTAssertNil(model.draftError)
        XCTAssertFalse(model.canApply)
        XCTAssertFalse(model.canClear)

        model.latitudeText = " 90 "
        XCTAssertNil(model.draftPoint)
        XCTAssertNotNil(model.draftError)
        model.longitudeText = " -180\n"
        XCTAssertEqual(model.draftPoint, try GeoPoint(latitude: 90, longitude: -180))
        XCTAssertNil(model.draftError)
        XCTAssertFalse(model.canApply, "有效草稿本身并不代表已有目标设备。")

        for (latitude, longitude) in [
            ("91", "120"), ("30", "-181"), ("nan", "0"),
            ("0", "inf"), ("30,5", "120"), ("abc", "0")
        ] {
            model.latitudeText = latitude
            model.longitudeText = longitude
            XCTAssertNil(model.draftPoint)
            XCTAssertNotNil(model.draftError)
            XCTAssertFalse(model.canApply)
        }

        model.latitudeText = ""
        model.longitudeText = ""
        XCTAssertNil(model.draftPoint)
        XCTAssertNil(model.draftError)
    }

    /// 地图合法坐标只更新草稿，非法坐标不覆盖现有合法草稿。
    @MainActor
    func testMapPointOnlyEditsDraft() async throws {
        let model = MacConsoleModel()
        model.selectMapPoint(CLLocationCoordinate2D(latitude: -33.9, longitude: 151.2))
        let original = try GeoPoint(latitude: -33.9, longitude: 151.2)
        XCTAssertEqual(model.draftPoint, original)
        XCTAssertNil(model.draftError)

        model.selectMapPoint(CLLocationCoordinate2D(latitude: 100, longitude: 0))
        model.selectMapPoint(CLLocationCoordinate2D(latitude: 0, longitude: .nan))
        XCTAssertEqual(model.draftPoint, original)
        XCTAssertTrue(model.devices.isEmpty)
        XCTAssertNil(model.activity)
    }

    /// 未切换模式、未配置本机解释器或 UDID 格式错误时拒绝添加目标。
    @MainActor
    func testManualTargetRequiresModernConfigurationAndValidUDID() async throws {
        let model = MacConsoleModel()
        model.manualDeviceID = firstID
        XCTAssertEqual(model.backendMode, .automatic)
        XCTAssertFalse(model.canAddManualTarget)
        await model.addManualTarget()
        XCTAssertTrue(model.deviceIDs.isEmpty)

        model.changeBackendMode(.modern)
        model.manualDeviceID = firstID
        XCTAssertFalse(model.canAddManualTarget)
        await model.addManualTarget()
        XCTAssertTrue(model.deviceIDs.isEmpty)

        await model.changePythonURL(URL(fileURLWithPath: "/usr/bin"))
        XCTAssertNil(model.modernPythonURL)
        XCTAssertNotNil(model.configurationError)
        XCTAssertFalse(model.canAddManualTarget)

        await model.changePythonURL(testExecutable)
        XCTAssertEqual(model.modernPythonURL, testExecutable)
        XCTAssertNil(model.configurationError)
        XCTAssertTrue(model.canAddManualTarget)

        for id in ["", "-u", "00008030-001122334455zzzz", "a b", "00008030-001122334455\naabb"] {
            model.manualDeviceID = id
            XCTAssertFalse(model.canAddManualTarget)
            await model.addManualTarget()
            XCTAssertTrue(model.deviceIDs.isEmpty)
        }
    }

    /// 两种 UDID 格式均可选择；大小写和首尾空白不为同一目标创建重复会话。
    @MainActor
    func testManualSelectionNormalizesAndDeduplicatesTargets() async throws {
        let model = await configuredModernModel()
        model.manualDeviceID = "  \(firstID.uppercased())\n"
        XCTAssertTrue(model.canAddManualTarget)
        await model.addManualTarget()
        XCTAssertEqual(model.deviceIDs, [firstID])
        XCTAssertEqual(model.selectedDeviceID, firstID)
        XCTAssertEqual(model.selectedDevice?.status, .idle)
        XCTAssertEqual(model.selectedDevice?.isAvailable, true)

        model.manualDeviceID = firstID
        await model.addManualTarget()
        XCTAssertEqual(model.deviceIDs, [firstID])

        model.manualDeviceID = secondID.uppercased()
        await model.addManualTarget()
        XCTAssertEqual(model.deviceIDs, [firstID, secondID].sorted())
        XCTAssertEqual(model.selectedDeviceID, secondID)

        model.selectedDeviceID = firstID
        XCTAssertEqual(model.selectedDevice?.status, .idle)
        model.selectedDeviceID = nil
        XCTAssertNil(model.selectedDevice)
        XCTAssertFalse(model.canApply)
        XCTAssertFalse(model.canClear)
    }

    /// 操作入口沿用 UI 门禁；不完整草稿或未选目标时不会开始后端操作。
    @MainActor
    func testInvalidDraftAndMissingTargetBlockOperations() async throws {
        let model = await configuredModernModel()
        model.manualDeviceID = firstID
        await model.addManualTarget()
        model.latitudeText = "-91"
        model.longitudeText = "0"
        XCTAssertFalse(model.canApply)
        XCTAssertTrue(model.canClear, "清除不依赖草稿坐标。")
        await model.applyDraft()
        XCTAssertNil(model.activity)
        XCTAssertEqual(model.selectedDevice?.status, .idle)
        XCTAssertNil(model.selectedDevice?.error)

        model.latitudeText = "0"
        XCTAssertTrue(model.canApply)
        model.selectedDeviceID = "未知目标"
        XCTAssertFalse(model.canApply)
        XCTAssertFalse(model.canClear)
        await model.applyDraft()
        await model.clearSelectedDevice()
        XCTAssertNil(model.activity)
        XCTAssertEqual(model.devices[firstID]?.status, .idle)
        XCTAssertNil(model.devices[firstID]?.error)
    }

    /// 主机休眠使手动确认失效，但保留目标记录；重新确认同一 ID 后才恢复操作门禁。
    @MainActor
    func testSleepInvalidatesManualTargetUntilReconfirmed() async throws {
        let model = await configuredModernModel()
        model.manualDeviceID = firstID
        await model.addManualTarget()
        model.selectMapPoint(CLLocationCoordinate2D(latitude: 0, longitude: 0))
        XCTAssertTrue(model.canApply)
        XCTAssertTrue(model.canClear)

        await model.invalidateConnectionsForSleep()
        XCTAssertEqual(model.deviceIDs, [firstID])
        XCTAssertEqual(model.selectedDeviceID, firstID)
        XCTAssertEqual(model.selectedDevice?.isAvailable, false)
        XCTAssertEqual(model.selectedDevice?.status, .idle)
        XCTAssertFalse(model.canApply)
        XCTAssertFalse(model.canClear)
        XCTAssertFalse(model.isBusy)
        await model.applyDraft()
        await model.clearSelectedDevice()
        XCTAssertNil(model.selectedDevice?.error)

        await model.addManualTarget()
        XCTAssertEqual(model.deviceIDs, [firstID])
        XCTAssertEqual(model.selectedDevice?.isAvailable, true)
        XCTAssertTrue(model.canApply)
        XCTAssertTrue(model.canClear)
    }

    /// 空闲模式切换清除旧模式的目标列表及选择，但不破坏地图草稿。
    @MainActor
    func testIdleBackendSwitchPreservesDraftAndDiscardsTargets() async throws {
        let model = await configuredModernModel()
        model.manualDeviceID = firstID
        await model.addManualTarget()
        let point = try GeoPoint(latitude: 31.25, longitude: 121.5)
        model.selectMapPoint(CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude))
        XCTAssertTrue(model.canChangeBackendMode)

        model.changeBackendMode(.legacy)
        XCTAssertEqual(model.backendMode, .legacy)
        XCTAssertTrue(model.deviceIDs.isEmpty)
        XCTAssertNil(model.selectedDeviceID)
        XCTAssertTrue(model.manualDeviceID.isEmpty)
        XCTAssertEqual(model.draftPoint, point)
        XCTAssertFalse(model.canApply)
        XCTAssertFalse(model.canClear)
        XCTAssertFalse(model.canChangePython)
    }

    /// 无副作用的系统可执行文件，仅用于满足模型文件配置检查，不执行真实 Python/helper。
    private var testExecutable: URL { URL(fileURLWithPath: "/usr/bin/true") }

    /// 构造真实模型并配置空闲现代后端；不会启动任何子进程或访问设备。
    @MainActor
    private func configuredModernModel() async -> MacConsoleModel {
        let connected = [firstID, secondID].map { PortableDevice(id: $0, name: nil, network: false) }
        let model = MacConsoleModel(attachedDevices: { connected })
        model.changeBackendMode(.modern)
        await model.changePythonURL(testExecutable)
        XCTAssertNil(model.configurationError)
        XCTAssertEqual(model.modernPythonURL, testExecutable)
        return model
    }
}

extension MacConsoleModelTests {
    /// 三种链路切换时撤销旧目标与接收码，USB 遥控无法按蓝牙 UUID 寻址。
    @MainActor
    func testBluetoothModeSwitchesWithWiFiAndUSB() {
        let model = MacConsoleModel()
        for next in [ConsoleBackendMode.wireless, .wired] {
            model.changeBackendMode(.bluetooth)
            let id = UUID().uuidString
            model.selectedDeviceID = id
            model.bluetoothCode = "123456"
            XCTAssertFalse(model.backendMode.supportsUSBController)
            model.changeBackendMode(next)
            XCTAssertEqual(model.backendMode, next)
            XCTAssertNil(model.selectedDeviceID)
            model.changeBackendMode(.bluetooth)
            model.selectedDeviceID = id
            XCTAssertTrue(model.bluetoothCode.isEmpty)
        }
    }
}

extension MacConsoleModelTests {
    /// 无开发工具时也能列出 USB 新机，之后插拔和改走局域网保留同一目标。
    @MainActor
    func testPortableUSBDiscoveryDoesNotRequireXcodeOrPairing() async throws {
        actor Source {
            var rows = [PortableDevice(id: "00008030001122334455AABB", name: "iPhone", network: false),
                        PortableDevice(id: "00008030-001122334455aabb", name: nil, network: true)]
            func unplug() { rows.removeFirst() }
        }
        let source = Source()
        let forbidden = CoreDeviceLocationBackend(transport: nil) { _ in
            XCTFail("独立模式不应启动 devicectl")
            return ""
        }
        let model = MacConsoleModel(automaticBackend: forbidden, portableExecutable: URL(fileURLWithPath: "/test/helper"),
                                    attachedDevices: { await source.rows })
        await model.refreshDevices()
        XCTAssertEqual(model.deviceIDs, [firstID])
        model.selectedDeviceID = firstID
        XCTAssertEqual(model.selectedDevice?.transportLabel, "USB")
        XCTAssertEqual(model.selectedDevice?.name, "iPhone")
        XCTAssertEqual(model.selectedDevice?.observedPairing, false)
        let version = model.selectedDevice?.sessionVersion
        await source.unplug()
        await model.refreshDevices()
        XCTAssertEqual(model.selectedDevice?.transportLabel, "Wi-Fi")
        XCTAssertEqual(model.selectedDevice?.sessionVersion, version)
    }
}
