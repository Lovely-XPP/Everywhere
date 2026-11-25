import Foundation
import HostSession
import ScenarioKit

/// 保留原无线后端入口，默认仍只选择局域网设备。
public typealias WirelessLocationBackend = CoreDeviceLocationBackend

/// 按所选传输枚举 CoreDevice 已配对真机；写入前重新核验 UDID、系统和链路。
public struct CoreDeviceLocationBackend: LocationBackend {
    /// CoreDevice 报告的设备传输类型。
    public enum Transport: String, Sendable {
        case wifi = "localNetwork"
        case usb = "wired"
    }
    private let transport: Transport?
    private let legacy: any LocationBackend

    /// 本次发现的物理设备；系统版本缺失时由显式路径决定可用操作。
    public struct Target: Equatable, Sendable {
        public let id: String
        public let name: String
        public let version: String?
        public let transport: Transport
    }

    private let run: @Sendable ([String]) async throws -> String

    /// 传入 nil 时发现 USB 和 Wi-Fi，操作时重新确认同一设备的当前连接。
    public init(transport: Transport? = .wifi) {
        self.transport = transport
        self.legacy = USBLocationBackend()
        run = { arguments in
            let tool = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/devicectl")
            if FileManager.default.isExecutableFile(atPath: tool.path) {
                return try await DeviceTool.run(tool, arguments, timeout: 35, jsonOutput: arguments.contains("--json-output"))
            }
            return try await DeviceTool.run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["devicectl"] + arguments, timeout: 35, jsonOutput: arguments.contains("--json-output"))
        }
    }

    /// 测试可注入工具回执，无需修改设备。
    init(transport: Transport? = .wifi, legacy: any LocationBackend = USBLocationBackend(),
         run: @escaping @Sendable ([String]) async throws -> String) {
        self.transport = transport
        self.legacy = legacy
        self.run = run
    }

    /// 仅返回 CoreDevice 报告为已配对且走所选链路的 iPhone 和 iPad。按设备名排序，UDID 用于消歧。
    public func devices() async throws -> [Target] {
        struct Listing: Decodable {
            struct Result: Decodable { let devices: [Device] }
            struct Device: Decodable {
                struct Hardware: Decodable { let reality, deviceType, udid: String? }
                struct Connection: Decodable { let pairingState, transportType, tunnelState: String? }
                struct Properties: Decodable { let name, osVersionNumber: String? }
                let hardwareProperties: Hardware?
                let connectionProperties: Connection?
                let deviceProperties: Properties?
            }
            let result: Result
        }
        let output = try await run(["list", "devices", "--quiet", "--timeout", "20", "--json-output", "-"])
        let listing = try JSONDecoder().decode(Listing.self, from: Data(output.utf8))
        var targets: [String: Target] = [:]
        for device in listing.result.devices {
            guard let link = device.connectionProperties, let hw = device.hardwareProperties,
                  link.pairingState == "paired", let type = link.transportType.flatMap(Transport.init(rawValue:)),
                  transport == nil || transport == type,
                  link.tunnelState != "unavailable", hw.reality == "physical",
                  hw.deviceType == "iPhone" || hw.deviceType == "iPad",
                  let id = hw.udid, !id.isEmpty else { continue }
            let key = id.lowercased()
            if targets[key]?.transport == .usb { continue }
            targets[key] = Target(id: id, name: device.deviceProperties?.name ?? id,
                                  version: device.deviceProperties?.osVersionNumber, transport: type)
        }
        return targets.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// 对指定标识执行实时只读查询，并在查询后再次确认仍为已配对的无线真机。
    public func verifyWirelessDevice(id: String) async throws -> Target {
        func match() async throws -> Target {
            let normalized = id.replacingOccurrences(of: "-", with: "").lowercased()
            let candidates = try await devices().filter { $0.id.replacingOccurrences(of: "-", with: "").lowercased() == normalized }
            guard transport == .wifi, candidates.count == 1 else {
                throw BackendPreflightError("Xcode 未将此 IP 对应的设备列为已配对的无线真机。")
            }
            return candidates[0]
        }
        let target = try await match()
        _ = try await run(["device", "info", "lockState", "--device", target.id, "--quiet", "--timeout", "8"])
        return try await match()
    }

    /// 将经过验证的十进制度坐标提交给所选设备。
    public func set(_ point: GeoPoint, deviceID: String) async throws {
        try await change(deviceID, point: point)
    }

    /// 显式清除；始终重新核验设备，不从上次设点的缓存推断恢复结果。
    public func clear(deviceID: String) async throws {
        try await change(deviceID, point: nil)
    }

    private func change(_ id: String, point: GeoPoint?) async throws {
        let targets: [Target]
        do {
            targets = try await devices()
            try Task.checkCancellation()
        } catch {
            throw BackendPreflightError("未发送定位命令，无法核对目标设备。\(error.localizedDescription)")
        }
        guard let target = targets.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame }) else {
            throw DeviceConnectionLostError("目标已离开所选链路或配对已失效，请重新连接并刷新。")
        }
        if target.transport == .usb {
            guard let major = target.version?.split(separator: ".").first.flatMap({ Int($0) }), major >= 16 else {
                throw BackendPreflightError("USB 自动路径需要识别到 iOS/iPadOS 16 或更新版本，尚未发送命令。")
            }
            if major == 16 {
                if let point { try await legacy.set(point, deviceID: id) }
                else { try await legacy.clear(deviceID: id) }
                return
            }
        }
        let nativeCommand = point == nil ? "clear" : "coordinate"
        do {
            _ = try await run(["help", "device", "simulate", "location", nativeCommand])
            try Task.checkCancellation()
        } catch is CancellationError {
            throw BackendPreflightError("操作已取消，尚未发送定位命令。")
        } catch {
            throw BackendPreflightError("无法确认本机 Xcode 支持定位命令 \(nativeCommand)，尚未发送。\(error.localizedDescription)")
        }
        // 等号确保 devicectl 将南纬、西经的负号解析为坐标的一部分。
        let command = point.map { ["coordinate", "--latitude=\($0.latitude)", "--longitude=\($0.longitude)"] } ?? ["clear"]
        _ = try await run(["device", "simulate", "location"] + command + ["--device", id, "--timeout", "30"])
    }
}
