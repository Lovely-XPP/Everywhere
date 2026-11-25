import Darwin
import Foundation
import HostSession
import ScenarioKit

/// P0 实验后端：通过单个持续运行的本地 Python 辅助进程控制用户已信任的 USB 真机。
/// 每个实例固定一台设备，不自动发现、配对、切换设备或重发旧定位命令。
/// 辅助进程的成功回执只说明开发定位接口已返回，不表示真机或第三方 App 实际位置改变。
public actor ModernLocationBackend: LocationBackend {
    private var pythonURL: URL
    private var scriptURL: URL?
    private let transport: String
    private let didDisconnect: @Sendable () -> Void
    private var boundDeviceID: String?
    private var worker: Worker?
    private var retiringWorker: Worker?
    private var busy = false
    private var hasActivePoint = false
    private var requiresClear = false

    /// 配置本地辅助进程，不访问设备或启动进程。
    /// - Parameters:
    ///   - pythonURL: 用户选择的本地 Python 可执行文件 URL。
    ///   - scriptURL: 随 App 提供的现代后端 Python 脚本文件 URL。
    ///   - didDisconnect: 已有设点未清除且观察到非预期通信中断时调用的回调；不在主 actor 调用。
    public init(pythonURL: URL, scriptURL: URL,
                didDisconnect: @escaping @Sendable () -> Void = {}) {
        self.transport = "USB"
        self.pythonURL = pythonURL
        self.scriptURL = scriptURL
        self.didDisconnect = didDisconnect
    }

    /// 发布包直接运行冻结的客户端，无需目标 Mac 安装 Python 或 Xcode。
    public init(executable: URL, transport: CoreDeviceLocationBackend.Transport?,
                didDisconnect: @escaping @Sendable () -> Void = {}) {
        self.pythonURL = executable
        self.scriptURL = nil
        self.transport = transport.map { $0 == .usb ? "USB" : "Network" } ?? "auto"
        self.didDisconnect = didDisconnect
    }

    /// 有限时长的只读设备查询或由用户发起的 USB 配对准备；参数直接交给包内程序。
    public static func discoverPeers(using executable: URL) async throws -> Data {
        Data(try await DeviceTool.run(executable, ["--nearby"], timeout: 18, jsonOutput: true).utf8)
    }

    public static func prepareWiFi(using executable: URL, device: String) async throws {
        guard isUDID(device) else { throw ModernError.invalidDevice }
        _ = try await DeviceTool.run(executable, ["--prepare-wifi", "--udid", device], timeout: 70)
    }

    deinit {
        worker?.shutdown()
        retiringWorker?.shutdown()
    }

    /// 更新未来启动辅助进程使用的文件路径；不替换正在运行的进程、不重发命令。
    /// - Parameters:
    ///   - pythonURL: 新的本地 Python 可执行文件 URL。
    ///   - scriptURL: 新的本地辅助脚本文件 URL。
    /// - Throws: 有命令执行中、文件路径无效或调用取消。
    public func updatePaths(pythonURL: URL, scriptURL: URL) async throws {
        try Task.checkCancellation()
        guard !busy else { throw ModernError.busy }
        try Self.validatePaths(pythonURL: pythonURL, scriptURL: scriptURL)
        self.pythonURL = pythonURL
        self.scriptURL = scriptURL
    }

    /// 向指定设备发送一次定点命令并等待匹配的回执。
    /// 已取消的调用不会继续发送；发出后取消会关闭进程并尝试清除，由会话记录结果未知。
    /// - Parameters:
    ///   - point: 已校验的 WGS 84 坐标，单位为度。
    ///   - deviceID: 用户指定的目标 USB 设备 UDID，不得在实例中更换。
    /// - Throws: 未发送前的错误为 `BackendPreflightError`；发送后的失败或取消不代表已清除。
    public func set(_ point: GeoPoint, deviceID: String) async throws {
        try await execute(Request(command: "set", point: point), deviceID: deviceID)
    }

    /// 向同一设备发送清除命令并等待匹配的回执；清除成功后正常关闭辅助进程。
    /// 允许在连接中断后重新创建辅助进程以尝试清除，不自动重放设点。
    /// - Parameter deviceID: 用户指定的目标 USB 设备 UDID。
    /// - Throws: 未发送前的错误为 `BackendPreflightError`；发送后的错误或取消不保证设备恢复。
    public func clear(deviceID: String) async throws {
        try await execute(Request(command: "clear", point: nil), deviceID: deviceID)
    }

    /// 限定单次命令及单一目标，完成握手、写入及回执校验。
    private func execute(_ request: Request, deviceID: String) async throws {
        guard !busy else { throw BackendPreflightError(ModernError.busy.localizedDescription) }
        guard Self.isUDID(deviceID), boundDeviceID == nil || boundDeviceID == deviceID else {
            throw BackendPreflightError(ModernError.invalidDevice.localizedDescription)
        }
        guard request.command != "set" || !requiresClear else { throw ModernError.needsClear }
        boundDeviceID = deviceID
        busy = true
        defer { busy = false }
        var attemptedWrite = false
        do {
            try Task.checkCancellation()
            let current = try await readyWorker(deviceID: deviceID)
            try Task.checkCancellation()
            // 在一次写操作后即使失败也可能已有部分数据到达子进程，不再视为预检失败。
            let data = try JSONEncoder().encode(request)
            attemptedWrite = true
            try current.writeLine(data)
            // Python 自身的 DVT 调用有 15 秒上限，为其错误回执留出额外时间。
            let receipt = try await waitForEvent(from: current, timeout: .seconds(20))
            guard receipt.event == "receipt", receipt.requestID == request.requestID,
                  receipt.deviceID == deviceID, receipt.command == request.command else {
                throw ModernError.protocolFailure
            }
            guard receipt.status == "sent" else {
                throw ModernError.backendRejected(receipt.message ?? "辅助进程未确认接受命令。")
            }
            // 回执到达后若已观察到进程退出，不将其呈现为活动中的模拟位置。
            guard worker?.id == current.id, current.isHealthy else {
                throw ModernError.disconnected
            }
            hasActivePoint = request.command == "set"
            if request.command == "clear" {
                requiresClear = false
                retire(current, unexpected: false)
            }
        } catch {
            if attemptedWrite { requiresClear = true }
            if let current = worker {
                // 仅开始新命令的预检被取消且已有正常活动子进程时保留它。
                if attemptedWrite || !hasActivePoint || !current.isHealthy {
                    retire(current, unexpected: true)
                }
            }
            if !attemptedWrite {
                if request.command == "set", requiresClear { throw ModernError.needsClear }
                throw BackendPreflightError(error.localizedDescription)
            }
            throw error
        }
    }

    /// 使用当前健康子进程，或等待旧进程退出后启动新进程并核对设备身份。
    private func readyWorker(deviceID: String) async throws -> Worker {
        if let current = worker {
            guard current.isHealthy else {
                retire(current, unexpected: true)
                // 不能在未确认清除的情况下由一次设点请求隐式重连并重新执行。
                throw ModernError.disconnected
            }
            return current
        }
        if let retired = retiringWorker {
            let deadline = ContinuousClock.now + .seconds(40)
            while retired.isRunning {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw ModernError.oldProcessRunning }
                try await Task.sleep(for: .milliseconds(50))
            }
            retiringWorker = nil
        }
        try Self.validatePaths(pythonURL: pythonURL, scriptURL: scriptURL)
        let id = UUID()
        let current = try Worker(id: id, pythonURL: pythonURL, scriptURL: scriptURL,
                                 deviceID: deviceID, transport: transport) { [weak self] in
            Task { await self?.workerDisconnected(id) }
        }
        worker = current
        let ready = try await waitForEvent(from: current, timeout: .seconds(scriptURL == nil ? 300 : 90))
        guard ready.event == "ready", ready.deviceID == deviceID,
              let version = ready.productVersion, !version.isEmpty else {
            throw ModernError.protocolFailure
        }
        return current
    }

    /// 异步等待有界 JSONL 消息；stdout 及 stderr 始终由后台队列消费。
    private func waitForEvent(from current: Worker, timeout: Duration) async throws -> Event {
        let deadline = ContinuousClock.now + timeout
        while true {
            try Task.checkCancellation()
            guard worker?.id == current.id else { throw current.connectionError }
            guard ContinuousClock.now < deadline else { throw ModernError.timeout }
            if let data = try current.takeLine() {
                guard let event = try? JSONDecoder().decode(Event.self, from: data) else {
                    throw ModernError.protocolFailure
                }
                if event.event == "error" {
                    throw ModernError.backendRejected(event.message ?? "辅助进程报告连接或执行异常。")
                }
                return event
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 处理持久子进程的非预期退出，丢弃连接而不重放设点。
    private func workerDisconnected(_ id: UUID) {
        guard let current = worker, current.id == id else { return }
        retire(current, unexpected: true)
    }

    /// 回收连接，关闭 stdin 让辅助进程尝试清除，并防止旧进程尚未退出时启动新的连接。
    private func retire(_ current: Worker, unexpected: Bool) {
        guard worker?.id == current.id else { return }
        worker = nil
        retiringWorker = current
        let notify = unexpected && hasActivePoint
        if notify { requiresClear = true }
        hasActivePoint = false
        current.shutdown()
        if notify { didDisconnect() }
    }

    /// 只接受已存在的本地可执行文件和可读普通脚本文件，不经 shell 解释。
    private static func validatePaths(pythonURL: URL, scriptURL: URL?) throws {
        var isDirectory: ObjCBool = false
        guard pythonURL.isFileURL,
              FileManager.default.fileExists(atPath: pythonURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: pythonURL.path) else { throw ModernError.invalidPaths }
        guard let scriptURL else { return }
        guard scriptURL.isFileURL,
              FileManager.default.fileExists(atPath: scriptURL.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isReadableFile(atPath: scriptURL.path) else {
            throw ModernError.invalidPaths
        }
    }

    /// 允许 Apple UDID 常见的两种十六进制标识格式，不接受命令行选项或其他字符。
    private static func isUDID(_ value: String) -> Bool {
        value.range(of: "^(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16})$",
                    options: .regularExpression) == value.startIndex..<value.endIndex
    }

    /// Swift 到 Python 的单条 JSONL 请求；每次生成独立 requestID 以避免误用旧回执。
    private struct Request: Encodable {
        let requestID = UUID().uuidString
        let command: String
        let latitude: Double?
        let longitude: Double?

        init(command: String, point: GeoPoint?) {
            self.command = command
            latitude = point?.latitude
            longitude = point?.longitude
        }
    }

    /// Python 辅助进程的结构化事件；不同 event 类型允许字段缺失，调用方核对必需字段。
    private struct Event: Decodable {
        let event: String
        let requestID: String?
        let deviceID: String?
        let productVersion: String?
        let status: String?
        let command: String?
        let message: String?
    }

    /// 外部进程和后台 stdout/stderr 读取的线程安全封装；队列状态由 lock 保护。
    private final class Worker: @unchecked Sendable {
        let id: UUID
        private let process = Process()
        private let input = Pipe()
        private let output = Pipe()
        private let diagnostics = Pipe()
        private let lock = NSLock()
        private var readBuffer = Data()
        private var lines: [Data] = []
        private var lastFailureMessage: String?
        private var failed = false
        private var shuttingDown = false
        private let onDisconnect: @Sendable () -> Void

        /// 启动指定 Python 文件及固定参数；不传递可能重定向 USB 查询的环境变量。
        init(id: UUID, pythonURL: URL, scriptURL: URL?, deviceID: String, transport: String,
             onDisconnect: @escaping @Sendable () -> Void) throws {
            self.id = id
            self.onDisconnect = onDisconnect
            process.executableURL = pythonURL
            process.arguments = scriptURL.map { [$0.path, "--udid", deviceID] } ?? ["--udid", deviceID, "--transport", transport]
            process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C",
                                   "PYTHONUNBUFFERED": "1", "PYTHONNOUSERSITE": "1"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = diagnostics
            // 防止辅助进程突然退出导致 Mac 控制台写入关闭的管道时收到 SIGPIPE。
            let fd = input.fileHandleForWriting.fileDescriptor
            let flags = fcntl(fd, F_GETFL)
            guard flags != -1, fcntl(fd, F_SETNOSIGPIPE, 1) != -1,
                  fcntl(fd, F_SETFL, flags | O_NONBLOCK) != -1 else {
                throw ModernError.disconnected
            }
            process.terminationHandler = { [weak self] _ in
                // 正常管道 EOF 会先消费剩余输出；若 EOF 被意外继承的描述符阻塞，仍通知宿主。
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(1)) {
                    self?.fail()
                }
            }
            try process.run()
            DispatchQueue.global(qos: .userInitiated).async { [self] in drainOutput() }
            DispatchQueue.global(qos: .utility).async { [self] in drainDiagnostics() }
        }

        /// 是否还能使用同一子进程进行通信；失败或正在回收的进程不可复用。
        var isHealthy: Bool {
            lock.lock()
            defer { lock.unlock() }
            return process.isRunning && !failed && !shuttingDown
        }

        /// 子进程是否仍未退出；用于禁止新旧进程同时执行定位。
        var isRunning: Bool { process.isRunning }

        /// 最近结构化失败原因（如有），不会保存普通 stderr 日志。
        var connectionError: ModernError {
            lock.lock()
            defer { lock.unlock() }
            return connectionErrorLocked
        }

        private var connectionErrorLocked: ModernError {
            if let message = lastFailureMessage { return .backendRejected(message) }
            return .disconnected
        }

        /// 非阻塞地写入一条短 JSONL 请求，单次写入不超过 1024 字节。
        func writeLine(_ data: Data) throws {
            guard isHealthy, data.count < 1024 else { throw ModernError.disconnected }
            var line = data
            line.append(0x0A)
            let written = line.withUnsafeBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return -1 }
                return Darwin.write(input.fileHandleForWriting.fileDescriptor, baseAddress, bytes.count)
            }
            guard written == line.count else { throw ModernError.disconnected }
        }

        /// 从线程安全队列获取完整的一行；连接失败时不使用缓存的旧回执。
        func takeLine() throws -> Data? {
            lock.lock()
            defer { lock.unlock() }
            guard !failed, !shuttingDown else { throw connectionErrorLocked }
            return lines.isEmpty ? nil : lines.removeFirst()
        }

        /// 持续消费 stdout，单行上限 64 KiB、未消费队列上限 64 行；超限作为通信失败。
        private func drainOutput() {
            let reader = output.fileHandleForReading
            defer { try? reader.close(); fail() }
            while let data = readChunk(reader) {
                append(data)
            }
        }

        /// 始终消费 stderr，防止辅助进程因日志写满管道阻塞，不持久化 stderr 内容。
        private func drainDiagnostics() {
            let reader = diagnostics.fileHandleForReading
            defer { try? reader.close() }
            while readChunk(reader) != nil {}
        }

        /// 使用 POSIX 管道读取：有数据即返回，不等待填满缓冲区；被信号中断时重试读取。
        private func readChunk(_ handle: FileHandle) -> Data? {
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                    guard let address = bytes.baseAddress else { return -1 }
                    return Darwin.read(handle.fileDescriptor, address, bytes.count)
                }
                if count > 0 { return Data(buffer.prefix(count)) }
                if count == 0 { return nil }
                if errno != EINTR { return nil }
            }
        }

        /// 按换行分帧；所有未消费缓冲均有明确内存上限。
        private func append(_ data: Data) {
            lock.lock()
            guard !failed, !shuttingDown else { lock.unlock(); return }
            readBuffer.append(data)
            var invalid = false
            while let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = Data(readBuffer[..<newline])
                readBuffer.removeSubrange(readBuffer.startIndex...newline)
                if line.count > 65_536 || lines.count >= 64 {
                    invalid = true
                    break
                }
                if !line.isEmpty {
                    if let event = try? JSONDecoder().decode(Event.self, from: line),
                       event.event == "error" || event.status == "unknown" || event.status == "rejected",
                       let message = event.message {
                        lastFailureMessage = String(message.prefix(512))
                    }
                    lines.append(line)
                }
            }
            if readBuffer.count > 65_536 { invalid = true }
            lock.unlock()
            if invalid { fail() }
        }

        /// 记录一次非预期通信失败，通知外层 actor 丢弃关联子进程。
        private func fail() {
            lock.lock()
            let notify = !failed && !shuttingDown
            failed = true
            readBuffer.removeAll()
            lines.removeAll()
            lock.unlock()
            if notify { onDisconnect() }
        }

        /// 关闭 stdin 让辅助进程自行退出并尝试清除；给正在执行的指令与清除各留出等待时间。
        /// 不将关闭或终止进程等同于清除回执；后续请求需等旧进程实际退出。
        func shutdown() {
            lock.lock()
            guard !shuttingDown else { lock.unlock(); return }
            shuttingDown = true
            lock.unlock()
            try? input.fileHandleForWriting.close()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(20)) { [self] in
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(35)) { [self] in
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    /// 转换后台错误为面向用户的说明，不推断设备位置已恢复。
    private enum ModernError: LocalizedError {
        case busy, invalidDevice, invalidPaths, disconnected, oldProcessRunning, timeout, protocolFailure, needsClear
        case backendRejected(String)

        var errorDescription: String? {
            switch self {
            case .busy: return "该设备仍有命令执行中。"
            case .invalidDevice: return "设备 UDID 格式无效或与本会话目标不一致。"
            case .invalidPaths: return "请确认 Python 可执行文件及现代后端脚本已正确配置。"
            case .disconnected: return "辅助进程连接已中断，无法确认设备位置状态。"
            case .oldProcessRunning: return "旧辅助进程尚未退出，请稍后重试清除。"
            case .timeout: return "等待辅助进程回执超时，无法确认设备位置状态。"
            case .protocolFailure: return "辅助进程返回的设备或消息标识不匹配。"
            case .needsClear: return "之前的模拟位置状态未知，需先明确发送清除命令。"
            case .backendRejected(let message): return String(message.prefix(512))
            }
        }
    }
}
