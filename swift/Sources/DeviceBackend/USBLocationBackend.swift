import Darwin
import Foundation
import HostSession
import ScenarioKit

/// P0 候选真机后端：使用本机已安装的 libimobiledevice 1.4.0 开发定位工具。
///
/// 仅尝试 iOS/iPadOS 16.x 的 USB 设备；系统及工具组合仍待真机验收。
/// 用户须提前信任此 Mac、启用开发者模式并通过正规开发工具准备匹配的开发者镜像。
/// 本后端不管理配对、开发者模式、开发者镜像或网络连接，也不读取配对密钥。
/// 工具成功退出仅代表本机工具执行结束，不提供真机采用或恢复位置的证明。
public struct USBLocationBackend: LocationBackend {
    /// 创建后端，不启动外部进程或访问设备。
    public init() {}

    /// 枚举当前通过 USB 连接的设备，不将设备发现视为开发定位能力验证。
    ///
    /// 在后台队列执行只读查询，支持任务取消；不会主动建立配对。
    /// - Returns: 唯一、排序后的设备 UDID 列表；无设备时为空。
    /// - Throws: 工具缺失、版本不匹配、执行超时、取消或无法解析输出。
    public func devices() async throws -> [String] {
        let tools = try Toolset(required: ["idevice_id"])
        try await tools.checkVersion("idevice_id")
        return try await tools.connectedDevices()
    }

    /// 使用已有信任关系向用户选中的 USB 设备发出开发定位设点命令。
    ///
    /// 预检及工具进程均在后台执行。取消会停止正在执行的工具，但已发出的指令无法撤回。
    /// - Parameters:
    ///   - point: 经过校验的 WGS 84 位置，单位为度。
    ///   - deviceID: 用户明确选定的设备 UDID，不允许空值或自动选择设备。
    /// - Throws: 不符合信任、USB 或版本要求，工具执行失败、超时或取消。
    public func set(_ point: GeoPoint, deviceID: String) async throws {
        let tools = try await checkedPrepare(deviceID: deviceID)
        _ = try await tools.run("idevicesetlocation", [
            "-u", deviceID, "--",
            String(point.latitude), String(point.longitude)
        ])
    }

    /// 使用已有信任关系向指定 USB 设备发出开发定位清除命令。
    ///
    /// 后台执行，支持任务取消。成功退出不表示设备已恢复实际位置，须独立观测。
    /// - Parameter deviceID: 用户明确选定的设备 UDID。
    /// - Throws: 不符合信任、USB 或版本要求，工具执行失败、超时或取消。
    public func clear(deviceID: String) async throws {
        let tools = try await checkedPrepare(deviceID: deviceID)
        _ = try await tools.run("idevicesetlocation", ["-u", deviceID, "reset"])
    }

    /// 仅将未发现失联且确定尚未发出写命令的失败转为普通预检错误，保留之前的会话状态。
    /// 已发现连接丢失时保留原错误，提示协调器当前设备位置状态无法确认。
    private func checkedPrepare(deviceID: String) async throws -> Toolset {
        do {
            let tools = try await prepare(deviceID: deviceID)
            try Task.checkCancellation()
            return tools
        } catch let error as DeviceConnectionLostError {
            throw error
        } catch is CancellationError {
            throw BackendPreflightError("操作已取消，尚未发送定位命令。")
        } catch {
            throw BackendPreflightError(error.localizedDescription)
        }
    }

    /// 每次写操作前重新检查设备身份、连接及已有配对记录；不缓存上一次信息。
    /// - Parameter deviceID: 用户选定的目标设备 UDID。
    /// - Returns: 预检中使用的同一套本机开发工具。
    /// - Throws: 设备身份、配对记录、系统或工具版本不符合候选范围，或查询被取消/失败。
    private func prepare(deviceID: String) async throws -> Toolset {
        try Task.checkCancellation()
        guard Self.isUDID(deviceID) else { throw BackendError.invalidDevice }

        let tools = try Toolset()
        for name in Toolset.names {
            try await tools.checkVersion(name)
        }
        guard try await tools.connectedDevices().contains(deviceID) else {
            throw DeviceConnectionLostError("选中的设备已不在 USB 设备列表。请重新连接并刷新。")
        }

        // list 仅读取已有配对记录；validate 在部分上游版本中可能调用自动尝试配对的握手。
        let paired = try await tools.run("idevicepair", ["list"])
        guard Self.lines(paired).contains(deviceID) else { throw BackendError.notPaired }

        // 使用 simple 查询避免主动配对；只读取目标系统及产品类别。
        let version = try await tools.run("ideviceinfo", ["-s", "-u", deviceID, "-k", "ProductVersion"])
        let product = try await tools.run("ideviceinfo", ["-s", "-u", deviceID, "-k", "ProductType"])
        let versionParts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(versionParts.count),
              versionParts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              versionParts.first == "16",
              product.range(of: "^(?:iPhone|iPad)[0-9]+,[0-9]+$", options: .regularExpression)
                  == (product.startIndex..<product.endIndex) else {
            throw BackendError.unsupportedDevice
        }

        guard try await tools.connectedDevices().contains(deviceID) else {
            throw DeviceConnectionLostError("预检期间选中的设备已不在 USB 设备列表。请重新连接并刷新。")
        }
        return tools
    }

    /// 只接受 Apple 真机 UDID 的常见十六进制标识格式，拒绝参数式、空白及其他字符。
    private static func isUDID(_ value: String) -> Bool {
        value.range(of: "^(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})$",
                    options: .regularExpression) == (value.startIndex..<value.endIndex)
    }

    /// 解析工具的一行一个标识输出，不将空行视为设备。
    private static func lines(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// 从固定安装目录选择本次操作需要的工具，不执行 shell 或自动安装。
    private struct Toolset: Sendable {
        static let names = ["idevice_id", "idevicepair", "ideviceinfo", "idevicesetlocation"]
        private let directory: URL

        init(required: [String] = Self.names) throws {
            let directories = ["/opt/homebrew/bin", "/usr/local/bin"]
            guard let path = directories.first(where: { directory in
                required.allSatisfy { FileManager.default.isExecutableFile(atPath: directory + "/" + $0) }
            }) else { throw BackendError.missingTools(required) }
            directory = URL(fileURLWithPath: path, isDirectory: true)
        }

        /// 核对已安装工具版本，避免未经评估的命令行兼容性变化。
        func checkVersion(_ name: String) async throws {
            let version = try await run(name, ["--version"])
            guard version == "\(name) 1.4.0" else { throw BackendError.unsupportedTool(name) }
        }

        /// 读取 USB 设备清单（明确传入 -l，排除网络设备）。
        func connectedDevices() async throws -> [String] {
            let output = try await run("idevice_id", ["-l"])
            let ids = USBLocationBackend.lines(output)
            guard ids.allSatisfy(USBLocationBackend.isUDID) else {
                throw BackendError.invalidOutput("idevice_id")
            }
            return Array(Set(ids)).sorted()
        }

        /// 将固定工具及参数传入独立进程，返回去除首尾空白的 UTF-8 输出。
        /// 每次调用最多等待 8 秒执行时间；取消或超时后终止进程，等待短暂退出宽限。
        func run(_ name: String, _ arguments: [String]) async throws -> String {
            let executable = directory.appendingPathComponent(name)
            return try await DeviceTool.run(executable, arguments)
        }
    }

    /// 提供面向 P0 操作人员的前置条件与子进程错误说明，不将失败解释为设备已恢复。
    private enum BackendError: LocalizedError {
        case missingTools([String])
        case unsupportedTool(String)
        case invalidDevice
        case notPaired
        case unsupportedDevice
        case invalidOutput(String)

        var errorDescription: String? {
            switch self {
            case .missingTools(let names):
                return "旧版 USB 模式需要 libimobiledevice 1.4.0。请确认以下工具均已安装在 /opt/homebrew/bin 或 /usr/local/bin 的同一目录：\(names.joined(separator: "、"))。"
            case .unsupportedTool(let name):
                return "\(name) 不符合候选工具版本 1.4.0，未继续执行。"
            case .invalidDevice:
                return "目标设备 UDID 格式无效。"
            case .notPaired:
                return "未发现此 Mac 对目标设备的已有配对记录。请先手动连接并确认设备信任。"
            case .unsupportedDevice:
                return "当前仅开放待验收的 iOS/iPadOS 16.x USB 开发定位路径，未继续执行。"
            case .invalidOutput(let name):
                return "无法解析 \(name) 的输出。"
            }
        }
    }
}
