import DeviceBackend
import Combine
import Foundation
import IOBluetooth
import ScenarioKit

/// 管理单台手机的本地 iAP2 客户端。默认使用内置认证程序，也支持已有的外部程序。
@MainActor
final class IAP2LocationSession: ObservableObject {
    @Published var address = ""
    @Published private(set) var running = false
    @Published private(set) var status = "等待连接" { didSet { statusChannel.update(phoneReport) } }
    @Published private(set) var sharingError: String?
    private let statusChannel = IAP2StatusPeripheral()
    @Published private(set) var authenticated = false
    @Published private(set) var identified = false
    private var reportedTarget = ""
    var phoneReport: IAP2ConnectionReport {
        IAP2ConnectionReport(target: reportedTarget, authenticated: authenticated, message: status)
    }
    func shareStatus(_ enabled: Bool) {
        sharingError = nil
        statusChannel.onError = { [weak self] in self?.sharingError = $0 }
        statusChannel.update(phoneReport)
        statusChannel.setEnabled(enabled)
    }
    @Published private(set) var devices: [String: String] = [:]
    @Published private(set) var requestedPoint: GeoPoint?
    @Published private(set) var acknowledgedPoint: GeoPoint?
    @Published private(set) var updatingPoint = false
    @Published private(set) var reconnecting = false
    @Published private(set) var needsResume = false
    private var generation = 0
    private var chosenPhone: (address: String, name: String)?
    private var commandInput: FileHandle?
    private var process: Process?
    @Published private(set) var stopping = false
    private var restoring = false
    private var timedOut = false
    private var acknowledged = false
    private var watchdog: Task<Void, Never>?

    private let pairedDevices: @Sendable () -> [String: String]

    private let helpers: URL
    private var builtInProvider: URL { helpers.appendingPathComponent("mfi-auth") }
    init(helpers: URL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true),
         pairedDevices: @escaping @Sendable () -> [String: String] = {

            var list: [String: String] = [:]
            for device in IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [] {
                guard let key = device.addressString else { continue }
                list[key.replacingOccurrences(of: "-", with: ":").uppercased()] = device.name ?? "蓝牙设备"
            }
            return list
    }) {
        self.helpers = helpers
        self.pairedDevices = pairedDevices
    }

    /// 手动刷新的反馈独立于连接与认证状态；后台轮询不覆盖上次手动刷新结果。
    @Published private(set) var refreshingByRequest = false
    @Published private(set) var refreshFeedback = ""
    @Published private(set) var lastManualRefresh: Date?
    private var readingPairedDevices = false
    private var lastPairedDevices: [String: String]?

    /// 同时发生的手动刷新与轮询共用一次系统读取，结果只统计系统已配对记录。
    func refresh(userInitiated: Bool = false) async {
        guard !running else { return }
        if userInitiated { refreshingByRequest = true }
        guard !readingPairedDevices else { return }
        readingPairedDevices = true
        let paired = await Task.detached(operation: pairedDevices).value
        readingPairedDevices = false
        if refreshingByRequest {
            let summary = paired.isEmpty ? "未找到已配对设备" : "共 \(paired.count) 台"
            refreshFeedback = lastPairedDevices == paired ? "列表无变化 · " + summary : summary
            lastManualRefresh = Date()
            refreshingByRequest = false
        }
        lastPairedDevices = paired
        guard !running else { return }
        devices = paired
        if let chosenPhone, paired[chosenPhone.address] == nil {
            devices[chosenPhone.address] = chosenPhone.name
        }
        if devices[address] == nil { address = "" }
        guard reportedTarget.isEmpty else { return }
        if !paired.isEmpty && address.isEmpty { status = "请选择已配对的 iPhone。" }
        if paired.isEmpty { status = "Mac 未列出已配对的经典蓝牙设备。请点击「连接新 iPhone」搜索设备。" }
    }

    /// 显式选择即可探测。系统可能尚未将新设备加入配对清单。
    func connectPhone(address raw: String, name: String, helper: String) {
        guard !running else { return }
        let target = raw.replacingOccurrences(of: "-", with: ":").uppercased()
        chosenPhone = (target, name)
        devices[target] = name
        address = target
        start(helper: helper)
    }

    /// 创建无坐标的持续连接，只有主机确认选点后才向此进程写入定位命令。
    static func arguments(address: String, bridge: URL, helper: URL) -> [String] {
        ["connect", "--transport", "bluetooth", "--device", address,
         "--bluetooth-helper", bridge.path, "--auth-helper", helper.path]
    }

    /// 身份识别和配件认证均完成时，同一条通道可直接接收地图选点。
    var readyToSend: Bool {
        running && identified && authenticated && !stopping && !reconnecting && !updatingPoint
    }

    /// 捕获确认时的目标、进程和重连代次，失效连接上的确认不再执行。
    func preparePointSend(_ point: GeoPoint, jitter: Bool) -> (() -> Void)? {
        guard readyToSend, let connection = process else { return nil }
        let target = address
        let revision = generation
        return {
            guard self.address == target, self.process === connection, self.generation == revision else { return }
            self.updatePoint(point, jitter: jitter)
        }
    }

    /// 启动认证会话；选点稍后通过标准输入写入，停止时释放蓝牙连接。
    func start(helper: String) {
        guard !running, devices[address] != nil else { return }
        authenticated = false
        identified = false
        reportedTarget = devices[address] ?? "所选设备"
        let executable = helpers.appendingPathComponent("AccessoryLocation.app/Contents/MacOS/accessory-location")
        let bridge = helpers.appendingPathComponent("bluetooth-bridge")
        let files = FileManager.default
        guard files.isExecutableFile(atPath: executable.path), files.isExecutableFile(atPath: bridge.path) else {
            status = "App 内的 iAP2 客户端或蓝牙桥缺失，请打开完整的 Everywhere.app。"; return
        }
        let provider = helper.isEmpty ? builtInProvider : URL(fileURLWithPath: helper)
        var isDirectory: ObjCBool = false
        guard (helper.isEmpty || helper.hasPrefix("/")), files.fileExists(atPath: provider.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, files.isExecutableFile(atPath: provider.path) else {
            status = helper.isEmpty ? "App 内缺少配件认证程序，请打开完整的 Everywhere.app。" : "请选择本机可执行的配件认证程序。"
            return
        }
        let client = Process()
        client.executableURL = executable
        client.arguments = Self.arguments(address: address, bridge: bridge, helper: provider)
        client.currentDirectoryURL = helpers
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        client.environment = environment
        let input = Pipe()
        client.standardInput = input.fileHandleForReading
        let output = Pipe()
        client.standardOutput = output
        client.standardError = FileHandle.nullDevice
        do { try client.run() } catch { status = "启动 iAP2 客户端失败 · " + error.localizedDescription; return }
        try? output.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        commandInput = input.fileHandleForWriting
        requestedPoint = nil
        generation = 0
        needsResume = false
        reconnecting = false
        acknowledgedPoint = nil
        updatingPoint = false
        process = client
        running = true
        acknowledged = false
        stopping = false
        timedOut = false
        restoring = false
        status = "正在建立 iAP2 蓝牙会话…"
        watchdog = Task {
            do { try await Task.sleep(for: .seconds(220)) } catch { return }
            if self.process === client, !self.stopping {
                self.timedOut = true
                self.stop()
            }
        }
        Task {
            var failure: String?
            do {
                for try await line in output.fileHandleForReading.bytes.lines {
                    guard self.process === client else { break }
                    if !stopping, let data = line.data(using: .utf8),
                       let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let event = record["event"] as? String {
                        switch event {
                        case "reconnecting":
                            authenticated = false
                            identified = false
                            acknowledgedPoint = nil
                            updatingPoint = false
                            reconnecting = true
                            generation = record["generation"] as? Int ?? generation + 1
                            needsResume = record["needs_confirmation"] as? Bool ?? true
                            watchdog?.cancel()
                            watchdog = nil
                            status = "连接中断，等待 " + String(record["delay"] as? Int ?? 2)
                                + " 秒后重连同一台 iPhone（第 " + String(generation) + "/2 次）。"
                        case "reconnected":
                            reconnecting = false
                            needsResume = record["needs_confirmation"] as? Bool ?? true
                            status = needsResume ? "配件已重新认证，请确认地图选点并继续发送。" : "配件已重新认证，等待 iPhone 订阅位置。"
                        case "bluetooth_stage":
                            switch record["stage"] as? String {
                            case "baseband": status = "正在连接 iPhone，如系统提示配对，请在 Mac 和 iPhone 上确认。"
                            case "discovery": status = "经典蓝牙已连接，正在查询 iAP2 服务"
                            case "open": status = "已查询到 iAP2 服务，正在打开 RFCOMM"
                            default: break
                            }
                        case "rfcomm_connected": status = "RFCOMM 已连接，正在检测 iAP2"
                        case "link_ready": status = "iAP2 握手完成，等待配件识别"
                        case "identification_accepted":
                            identified = true
                            status = authenticated ? "iAP2 已连接 · 配件认证通过" : "iPhone 已识别配件，等待认证"
                        case "error":
                            authenticated = false
                            failure = Self.failureMessage(type: record["type"] as? String, detail: record["detail"] as? String, stage: status)
                            status = failure ?? "iAP2 会话失败"
                        case "authentication_succeeded":
                            authenticated = true
                            status = "iAP2 已连接 · 配件认证通过"
                        case "location_requested":
                            let sentences = (record["sentences"] as? [Int])?.compactMap { [1: "GGA", 2: "RMC"][$0] }
                            if requestedPoint == nil {
                                status = "iPhone 已订阅位置，可发送地图选点"
                            } else if sentences?.isEmpty == true {
                                status = "收到位置请求，但未订阅支持的 GGA 或 RMC · 等待下一次订阅"
                            } else {
                                status = "iPhone 已请求位置" + (sentences.map { " · " + $0.joined(separator: "、") } ?? "")
                            }
                        case "location_stopped": status = "iPhone 已暂停位置订阅 · 蓝牙会话保持连接"
                        case "target_updated":
                            updatingPoint = false
                            needsResume = false
                            status = "客户端已更新选点，等待新坐标的链路回执"
                        case "location_link_acknowledged":
                            if let lat = record["latitude"] as? Double, let lon = record["longitude"] as? Double {
                                acknowledgedPoint = try? GeoPoint(latitude: lat, longitude: lon)
                            }
                            acknowledged = true
                            let count = record["count"] as? Int ?? 1
                            let time = Date.now.formatted(date: .omitted, time: .standard)
                            status = "定位包已获链路确认 · 累计回执 \(count) · \(time)"
                        default: break
                        }
                        if identified, authenticated, watchdog != nil {
                            watchdog?.cancel()
                            watchdog = nil
                        }
                    }
                }
            } catch { if client.isRunning { client.terminate() } }
            await Task.detached { client.waitUntilExit() }.value
            try? output.fileHandleForReading.close()
            guard self.process === client else { return }
            watchdog?.cancel()
            watchdog = nil
            let last = status
            authenticated = false
            if timedOut { status = "等待 iPhone 完成握手或认证超时，会话已结束。" }
            else if let failure { status = failure }
            else if !stopping && client.terminationStatus != 0 { status = "客户端退出（\(client.terminationStatus)），最后阶段 · " + last }
            else if restoring { status = "配件位置输出已结束。请在 iPhone 地图点“我的位置”，核对新的定位样本。" }
            else if acknowledged { status = "会话已结束 · 本次定位数据收到回执，请在 iPhone 核对定位恢复情况。" }
            else if stopping { status = "会话已停止。" }
            else { status = "会话已结束 · " + last }
            try? commandInput?.close()
            commandInput = nil
            requestedPoint = nil
            updatingPoint = false
            acknowledgedPoint = nil
            process = nil
            reconnecting = false
            needsResume = false
            running = false
        }
    }

    /// 向当前发送会话提交新坐标。每次只允许一个待处理命令，主机管道内只有一行短消息。
    func updatePoint(_ point: GeoPoint, jitter: Bool) {
        guard readyToSend, let commandInput else { return }
        do {
            var line = try JSONSerialization.data(withJSONObject: ["latitude": point.latitude, "longitude": point.longitude, "generation": generation, "jitter": jitter])
            line.append(10)
            try commandInput.write(contentsOf: line)
            requestedPoint = point
            updatingPoint = true
            status = "已提交地图选点，等待客户端处理"
        } catch {
            status = "无法更新当前会话的坐标，请停止后重新发送。"
        }
    }

    /// 转换内置客户端和桥的故障报告。外部认证程序的原始输出仅用于分类。
    static func failureMessage(type: String?, detail: String?, stage: String) -> String {
        let reason = detail ?? ""
        if ["EW_BASEBAND_ERROR ", "EW_SDP_ERROR ", "EW_OPEN_ERROR "].contains(where: reason.hasPrefix) {
            let fields = reason.split(separator: " ").dropFirst().map { $0.split(separator: "=", maxSplits: 1) }
            func value(_ key: String) -> String? {
                fields.first(where: { $0.count == 2 && $0[0] == key }).map { String($0[1]) }
            }
            if let code = value("status"), code.range(of: "^0x[0-9a-f]{8}$", options: .regularExpression) != nil {
                if reason.hasPrefix("EW_BASEBAND_ERROR ") { return "经典蓝牙链路未建立（" + code + "），请在 iPhone 打开「设置 → 蓝牙」，确认 Mac 配对记录仍在后重试。" }
                if reason.hasPrefix("EW_SDP_ERROR ") { return "查询 iPhone 蓝牙服务失败（" + code + "）。请解锁手机后重试。" }
                if let channel = value("channel").flatMap(Int.init), (1...30).contains(channel) {
                    let source = value("record") == "live" ? "本次查询" : "缓存"
                    let summary = "RFCOMM 通道 " + String(channel) + "（" + source + "，" + code + "）"
                    switch value("cause") {
                    case "busy": return summary + "正忙，请先结束其他正在使用此通道的会话。"
                    case "permission": return summary + "打开权限被拒绝，请检查 Mac 蓝牙权限。"
                    case "timeout": return summary + "打开超时，请解锁 iPhone 并保持在附近。"
                    default: return summary + "打开失败。"
                    }
                }
            }
        }
        switch reason {
        case "Unable to read the local Bluetooth controller address", "Expected a six-byte Bluetooth address":
            return "无法读取蓝牙地址，请检查 Mac 蓝牙开关及「隐私与安全性 → 蓝牙」中的 Everywhere 权限。"
        case "Bluetooth target unavailable": return "无法打开所选设备，请重新搜索 iPhone。"
        case "Selected device is not paired": return "所选 iPhone 尚未完成经典蓝牙配对，请核对两端的系统配对状态。"
        case "Bluetooth service discovery failed": return "蓝牙服务查询失败，请解锁手机、靠近 Mac 后重新检测。"
        case "iAP2 service unavailable": return "手机已配对，但本次查询未发现 iAP2 服务。可解锁手机后重新检测，或切换到软件模拟模式。"
        case "RFCOMM open failed": return "已发现 iAP2 服务，但 RFCOMM 通道未能打开。"
        case "Accessory authentication required; no credential configured": return "iPhone 已要求配件认证，当前未选择认证程序。"
        case "Authentication provider: 本机签名身份与内置证书不匹配。": return "本机签名身份与内置证书不匹配。"
        case "Accessory authentication failed": return "iPhone 拒绝了配件认证，请核对认证程序使用的配件身份。"
        case "Authentication provider: 本机缺少配件签名私钥。": return "iPhone 已要求配件认证，本机缺少配件签名私钥。"
        default:
            if reason.hasPrefix("Authentication provider") || reason.lowercased().contains("certificate") {
                return "配件认证程序未能提供有效响应，请检查其配置。"
            }
            if reason.hasPrefix("Identification rejected") { return "iPhone 拒绝了配件识别信息。" }
            if type == "TimeoutError" { return "等待 iPhone 响应超时 · " + stage }
            if ["IncompleteReadError", "BrokenPipeError", "EOFError", "ConnectionError"].contains(type ?? "") {
                return "蓝牙通道在会话中断开 · " + stage
            }
            return "iAP2 会话失败（" + (type ?? "未知错误") + "）· " + stage
        }
    }

    /// 有本次配件选点时允许恢复，手机暂停订阅或正在重连时仍可结束输出。
    var canRestore: Bool { running && !stopping && requestedPoint != nil }

    /// 仅结束用户确认的设备、客户端和重连代次。配件退出后由手机重新选择位置源。
    func prepareRestore() -> (() -> Void)? {
        guard canRestore, let client = process else { return nil }
        let target = address
        let revision = generation
        return {
            guard self.process === client, self.address == target, self.generation == revision, self.canRestore else { return }
            self.restoring = true
            self.stop()
        }
    }

    /// 停止当前客户端并释放其蓝牙连接；系统真实坐标恢复由手机独立观测。
    func stop() {
        guard let client = process, client.isRunning, !stopping else { return }
        stopping = true
        authenticated = false
        status = restoring ? "正在停止配件位置输出…" : "正在结束 iAP2 会话…"
        if restoring {
            try? commandInput?.close()
            commandInput = nil
        } else { client.interrupt() }
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard self.process === client, client.isRunning else { return }
            if self.restoring {
                client.interrupt()
                try? await Task.sleep(for: .seconds(2))
                guard self.process === client, client.isRunning else { return }
            }
            client.terminate()
            try? await Task.sleep(for: .seconds(2))
            if self.process === client, client.isRunning { kill(client.processIdentifier, SIGKILL) }
        }
    }
}
