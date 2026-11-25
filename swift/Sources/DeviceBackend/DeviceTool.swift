import Darwin
import Foundation
import HostSession

/// 在后台以固定可执行路径和参数启动设备工具，限时等待，取消时终止子进程。
enum DeviceTool {
    /// 返回 UTF-8 标准输出；命令异常退出、输出过大、超时或取消时抛错。
    static func run(_ executable: URL, _ arguments: [String], timeout: Int = 8, jsonOutput: Bool = false) async throws -> String {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try Self.runProcess(executable, arguments, timeout: timeout, jsonOutput: jsonOutput, cancellation: cancellation)
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// 在后台线程限时等待子进程，使用私有临时文件收集输出以避免管道写满阻塞。
    /// 文件仅在本次进程期间存在，不写入项目或位置历史。错误时同样清理文件。
    private static func runProcess(_ executable: URL, _ arguments: [String],
                                   timeout: Int, jsonOutput: Bool, cancellation: CancellationFlag) throws -> String {
        if cancellation.isCancelled { throw CancellationError() }
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent("VirtualLocation-\(UUID().uuidString)")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        defer { try? fileManager.removeItem(at: directory) }
        let output = directory.appendingPathComponent("output")
        guard fileManager.createFile(atPath: output.path, contents: nil,
                                     attributes: [.posixPermissions: 0o600]) else {
            throw BackendPreflightError("无法创建工具输出文件。")
        }
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }

        let name = executable.lastPathComponent
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // 不继承 USBMUXD_SOCKET_ADDRESS 等可能将本机查询重定向到其他主机的环境变量。
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = writer
        // JSON 工具会把进度写入 stderr。独立保存诊断，避免破坏 JSON 或丢失失败原因。
        let diagnostics: FileHandle?
        let diagnosticURL = directory.appendingPathComponent("diagnostics")
        if jsonOutput {
            guard fileManager.createFile(atPath: diagnosticURL.path, contents: nil) else {
                throw BackendPreflightError("无法创建诊断输出文件。")
            }
            diagnostics = try FileHandle(forWritingTo: diagnosticURL)
        } else {
            diagnostics = nil
        }
        defer { try? diagnostics?.close() }
        process.standardError = diagnostics ?? writer
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        if cancellation.isCancelled { throw CancellationError() }
        try process.run()
        let deadline = DispatchTime.now() + .seconds(timeout)
        while exited.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            let cancelled = cancellation.isCancelled
            if cancelled || DispatchTime.now() >= deadline {
                if process.isRunning { process.terminate() }
                if exited.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
                    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                    _ = exited.wait(timeout: .now() + .seconds(1))
                }
                if cancelled { throw CancellationError() }
                throw ToolFailure("\(name) 执行超时。")
            }
        }
        if cancellation.isCancelled { throw CancellationError() }

        let reader = try FileHandle(forReadingFrom: output)
        defer { try? reader.close() }
        let limit = jsonOutput ? 4 * 1024 * 1024 : 65_536
        let data = try reader.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit, let decoded = String(data: data, encoding: .utf8) else {
            throw ToolFailure("无法解析 \(name) 的输出。")
        }
        let message = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              jsonOutput || !message.uppercased().contains("ERROR:") else {
            if let diagnosticsReader = try? FileHandle(forReadingFrom: diagnosticURL) {
                defer { try? diagnosticsReader.close() }
                if let bytes = try diagnosticsReader.read(upToCount: 1024), !bytes.isEmpty {
                    throw ToolFailure("\(name) 执行失败：\(String(decoding: bytes, as: UTF8.self))")
                }
            }
            throw ToolFailure("\(name) 执行失败（\(process.terminationStatus)）。\(message.prefix(512))")
        }
        return message
    }

    /// 跨任务与后台队列传递取消信号，所有可变状态均由锁保护。
    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    private struct ToolFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
