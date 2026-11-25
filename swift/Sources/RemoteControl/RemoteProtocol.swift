import Foundation

/// 经已信任的 USB 链路首次签发，供同一设备在后续网络连接中证明绑定。
public struct DeviceGrant: Codable, Equatable, Sendable {
    public let device: String
    public let token: String
    public init(device: String, token: String) { self.device = device; self.token = token }
}

/// 同一 TLS 连接使用请求 ID 对照回执。坐标单位为 WGS 84 十进制度，时间为绝对时间。
public struct RemoteRequest: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case status, apply, clear }
    public let id: UUID
    public let grant: DeviceGrant?
    public let expires: Date
    public let action: Action
    public let device: String?
    /// Mac 签发的目标会话版本；每次操作后更新，防止旧指令影响新会话。
    public let session: UUID?
    public let latitude: Double?
    public let longitude: Double?

    /// 固化提交时的目标与草稿；默认 30 秒内可开始执行，已开始的操作等待独立回执。
    public init(_ action: Action, target: RemoteTarget? = nil, latitude: Double? = nil,
                longitude: Double? = nil, grant: DeviceGrant? = nil, id: UUID = UUID(), expires: Date = Date().addingTimeInterval(30)) {
        self.grant = grant
        self.action = action
        self.id = id
        self.expires = expires
        device = target?.id
        session = target?.session
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// 恢复提示取决于 Mac 实际执行位置的目标，与手机遥控 Mac 所用的传输独立。
public enum LocationRecoveryScope: String, Codable, Sendable {
    case device, simulator, bluetoothApp

    public var button: String {
        switch self {
        case .device: return "恢复真实定位"
        case .simulator: return "清除模拟器定位"
        case .bluetoothApp: return "清除蓝牙位置"
        }
    }

    public var instructions: String {
        switch self {
        case .device: return "保持目标设备与 Mac 的连接。停止模拟后，请在目标设备打开地图，点“我的位置”，等待新的定位。"
        case .simulator: return "将移除模拟器当前的位置源。清除后，应用可能暂时收不到定位样本。"
        case .bluetoothApp: return "将移除手机应用地图上的蓝牙标记。接收保持开启，Mac 可以继续发送新位置。"
        }
    }

    public var receipt: String {
        switch self {
        case .device: return "已收到停止模拟的回执。请在目标设备的地图点“我的位置”，或在 Everywhere 的“诊断”中 核对新样本。如果仍停在旧点，可手动重启目标设备后再检查。"
        case .simulator: return "已清除模拟器位置源。模拟器没有真实 GPS 位置。"
        case .bluetoothApp: return "手机应用已确认移除蓝牙位置标记。"
        }
    }
}

/// Mac 提供的单台目标及最近一次连接检查、后端回执；不包含独立定位观测。
public struct RemoteTarget: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let session: UUID
    public let available: Bool
    public let needsClear: Bool
    public let detail: String
    /// 旧版本主机不会发送这两个字段。
    public let recoveryScope: LocationRecoveryScope?
    public let hasActiveLocation: Bool?
    public init(id: String, session: UUID, available: Bool, needsClear: Bool, detail: String,
                recoveryScope: LocationRecoveryScope? = nil, hasActiveLocation: Bool? = nil) {
        self.recoveryScope = recoveryScope
        self.hasActiveLocation = hasActiveLocation
        self.id = id
        self.session = session
        self.available = available
        self.needsClear = needsClear
        self.detail = detail
    }
}

/// 送达通知与执行结果分开发送；每条回执仅对应一个请求。
public struct RemoteReply: Codable, Sendable {
    public enum Phase: String, Codable, Sendable { case delivered, status, accepted, rejected, unknown }
    public let id: UUID
    public let phase: Phase
    public let message: String
    public let boundDevice: String?
    public let grant: DeviceGrant?
    public let targets: [RemoteTarget]
    public init(_ request: RemoteRequest, _ phase: Phase, _ message: String, targets: [RemoteTarget] = [], boundDevice: String? = nil, grant: DeviceGrant? = nil) {
        self.boundDevice = boundDevice
        self.grant = grant
        id = request.id
        self.phase = phase
        self.message = message
        self.targets = targets
    }
}

/// 通信帧、凭据或连接状态不符合预期时供界面展示的错误。
public struct RemoteError: LocalizedError {
    public let errorDescription: String?
    public init(_ message: String) { errorDescription = message }
}
