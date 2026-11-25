import Foundation
import ScenarioKit

/// Mac 本机定位会话使用的执行后端。
///
/// 后端的成功返回仅表示命令已被接受，不代表独立定位探针或其他 App 已观测到位置变化。
public protocol LocationBackend: Sendable {
    /// 请求设备采用指定位置。调用方接受异步执行及真机位置变化这一副作用。
    /// - Parameters:
    ///   - point: 已校验的 WGS 84 地理坐标。
    ///   - deviceID: 本机后端识别的目标设备标识。
    /// - Throws: 已确认没有发出命令且未发现失联时为 `BackendPreflightError`；已发现失联时为 `DeviceConnectionLostError`，否则为执行、通信或取消错误。
    func set(_ point: GeoPoint, deviceID: String) async throws

    /// 向指定设备发出清除请求并等待后端回执，不保证设备已恢复实际位置。
    /// - Parameter deviceID: 本机后端识别的目标设备标识。
    /// - Throws: 已确认没有发出命令且未发现失联时为 `BackendPreflightError`；已发现失联时为 `DeviceConnectionLostError`，否则为执行、通信或取消错误。
    func clear(deviceID: String) async throws
}

/// 后端确认未向设备发出本次命令时使用的前置检查错误。
///
/// 只有在执行方能确定本次操作没有设备位置副作用且未发现连接中断时才允许抛出；
/// 没有得到回执并不表示命令未发出，执行中的超时或中断不得标为此前置错误。
public struct BackendPreflightError: LocalizedError, Sendable {
    private let message: String

    /// 创建供调用方显示的前置错误。
    /// - Parameter message: 已知命令未发出的具体原因。
    public init(_ message: String) {
        self.message = message
    }

    /// 供界面呈现的前置错误原因。
    public var errorDescription: String? { message }
}

/// 后端已观察到目标设备连接丢失。即使本次命令尚未发出，也不能据此确认之前的设备位置状态。
public struct DeviceConnectionLostError: LocalizedError, Sendable {
    private let message: String

    /// 创建已发现设备连接中断的错误。
    /// - Parameter message: 连接中断的具体证据及用户可见说明。
    public init(_ message: String) {
        self.message = message
    }

    /// 供界面呈现的连接错误原因。
    public var errorDescription: String? { message }
}

/// Mac 主机掌握的会话执行状态，与设备的实际位置观测结果无关。
public enum SessionStatus: Equatable, Sendable {
    /// 尚未发出命令，或后端已确认清除。
    case idle
    /// 等待设点回执。
    case applying
    /// 后端已接受指定坐标。
    case accepted(GeoPoint)
    /// 等待清除回执。
    case clearing
    /// 未取得可靠回执；设备可能仍持有先前模拟位置。
    case unknown
}

/// 本机会话拒绝请求或无法确认回执的原因。
public enum SessionError: LocalizedError, Equatable, Sendable {
    /// 当前设备正在等待另一条命令的回执。
    case busy
    /// 上一条命令结果未知，需先确认清除。
    case needsClear
    /// 等待回执期间观察到连接中断，无法确认该命令对应的设备状态。
    case interrupted

    /// 供主机界面呈现的会话错误原因。
    public var errorDescription: String? {
        switch self {
        case .busy: return "目标设备正在执行另一条命令。"
        case .needsClear: return "上次命令的结果未知，请先清除定位。"
        case .interrupted: return "等待回执期间设备连接中断，结果未知。"
        }
    }
}

/// Mac 主机中面向单台设备的本地 P0 会话协调器。
///
/// 使用 actor 隔离会话状态，并通过状态门禁阻止等待后端时的重入。主机应为每台设备复用同一协调器。
/// 当前接口用于本机直接调用，不包含远程请求识别、过期处理或重连调度。
public actor DeviceSession {
    private let deviceID: String
    private let backend: any LocationBackend
    private var interrupted = false
    private var lastAcceptedAt: ContinuousClock.Instant?

    /// 可跨 actor 读取的仅后端回执级会话状态。
    public private(set) var status: SessionStatus = .idle

    /// 创建面向指定设备的会话；构造本身不接触设备。
    /// - Parameters:
    ///   - deviceID: 已由主机明确选定的后端设备标识。
    ///   - backend: 执行设点与清除的后端。
    public init(deviceID: String, backend: any LocationBackend) {
        self.deviceID = deviceID
        self.backend = backend
    }

    /// 在本会话 actor 内启动或更换定位点，并异步等待后端回执。
    ///
    /// 已取消的任务不会发出新命令。后端确认未发出命令且连接未中断时恢复原状态，
    /// 其他后端执行失败或取消错误使会话进入未知状态；
    /// 如已收到成功回执则保留已接受状态。等待期间其他命令将被拒绝。
    /// - Parameter point: 将交由后端执行的 WGS 84 位置。
    /// - Throws: `SessionError.busy`、`SessionError.needsClear`、`SessionError.interrupted`、`CancellationError` 或后端执行错误。
    public func apply(_ point: GeoPoint) async throws {
        _ = try await applyWithReceipt(point)
    }

    /// 返回 true 表示已向后端提交；false 表示复用两秒内同点的已有回执。
    public func applyWithReceipt(_ point: GeoPoint) async throws -> Bool {
        try Task.checkCancellation()
        switch status {
        case .applying, .clearing:
            throw SessionError.busy
        case .unknown:
            throw SessionError.needsClear
        case .accepted(point) where lastAcceptedAt.map({ $0.duration(to: .now) < .seconds(2) }) == true:
            return false
        case .idle, .accepted:
            break
        }

        let previousStatus = status
        interrupted = false
        status = .applying
        do {
            try await backend.set(point, deviceID: deviceID)
            guard !interrupted else { throw SessionError.interrupted }
            status = .accepted(point)
            lastAcceptedAt = .now
            return true
        } catch {
            status = error is BackendPreflightError && !interrupted ? previousStatus : .unknown
            throw error
        }
    }

    /// 在本会话 actor 内请求清除定位，并异步等待回执。
    ///
    /// 即使当前状态为未知或空闲，也允许主动清除。清除成功后仅回到回执级空闲状态，
    /// 不表示真机已恢复实际位置。进入时已取消的任务不会向设备发出命令；后端确认未发出命令
    /// 且连接未中断时恢复原状态，其他后端执行失败则记为未知。
    /// - Throws: `SessionError.busy`、`SessionError.interrupted`、`CancellationError` 或后端执行错误。
    public func clear() async throws {
        try Task.checkCancellation()
        switch status {
        case .applying, .clearing:
            throw SessionError.busy
        case .idle, .accepted, .unknown:
            break
        }

        let previousStatus = status
        interrupted = false
        status = .clearing
        do {
            try await backend.clear(deviceID: deviceID)
            guard !interrupted else { throw SessionError.interrupted }
            status = .idle
        } catch {
            status = error is BackendPreflightError && !interrupted ? previousStatus : .unknown
            throw error
        }
    }

    /// 记录主机观测到的设备连接中断，不会向设备发送任何请求。
    ///
    /// 已接受的会话立即转为未知。执行中的命令保持互斥门禁，待返回后转为未知；
    /// 不能把旧连接上的成功回执误认为新连接上的设备状态。
    public func markDisconnected() {
        switch status {
        case .accepted:
            status = .unknown
        case .applying, .clearing:
            interrupted = true
        case .idle, .unknown:
            break
        }
    }
}
