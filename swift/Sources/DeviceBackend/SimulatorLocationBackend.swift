import Foundation
import HostSession
import ScenarioKit

/// 显式选择已启动的 iOS 模拟器，通过同一 DeviceSession 检验手机遥控链路。
public struct SimulatorLocationBackend: LocationBackend {
    public init() {}

    /// 标准 Xcode 安装优先，否则使用当前 xcode-select 对应的工具。
    private func run(_ arguments: [String]) async throws -> String {
        let tool = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/simctl")
        if FileManager.default.isExecutableFile(atPath: tool.path) {
            return try await DeviceTool.run(tool, arguments)
        }
        return try await DeviceTool.run(URL(fileURLWithPath: "/usr/bin/xcrun"), ["simctl"] + arguments)
    }

    /// 返回已启动并可用的 iOS 模拟器 UUID；不启动或修改设备。
    public func devices() async throws -> [String] {
        struct Listing: Decodable {
            struct Device: Decodable { let udid: String; let state: String; let isAvailable: Bool }
            let devices: [String: [Device]]
        }
        let output = try await run(["list", "devices", "booted", "--json"])
        let list = try JSONDecoder().decode(Listing.self, from: Data(output.utf8))
        return list.devices.filter { $0.key.contains(".iOS-") }.flatMap(\.value)
            .filter { $0.isAvailable && $0.state == "Booted" && UUID(uuidString: $0.udid) != nil }
            .map(\.udid).sorted()
    }

    /// 向明确选中的模拟器提交 WGS 84 坐标（度）；成功仅表示 simctl 已返回。
    public func set(_ point: GeoPoint, deviceID: String) async throws {
        try await change(deviceID, ["set", "\(point.latitude),\(point.longitude)"])
    }

    /// 清除指定模拟器的位置源；模拟器没有真实 GPS 基线。
    public func clear(deviceID: String) async throws {
        try await change(deviceID, ["clear"])
    }

    private func change(_ id: String, _ arguments: [String]) async throws {
        guard UUID(uuidString: id) != nil else { throw BackendPreflightError("模拟器标识无效。") }
        guard try await devices().contains(id) else { throw DeviceConnectionLostError("模拟器已断开。") }
        _ = try await run(["location", id] + arguments)
    }
}
