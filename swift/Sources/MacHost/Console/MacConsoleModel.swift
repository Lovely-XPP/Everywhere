import Foundation
import Combine
import CoreLocation
import DeviceBackend
import HostSession
import RemoteControl
import ModernHelper
import ScenarioKit

/// Mac 控制台可选择的设备定位后端；具体设备组合的兼容性尚待真机实测。
enum ConsoleBackendMode: String, CaseIterable, Identifiable, Hashable {
    case automatic = "自动识别 USB / Wi-Fi"
    /// 按 CoreDevice 报告的 USB 目标及系统版本选择真机执行路径。
    case wired = "已配对真机 · USB 自动"
    /// 面向系统 16 的旧版直接 USB 开发服务。
    case legacy = "系统 16 · 旧版 USB"
    /// 面向系统 17.4 及其后续版本研究的 USB helper。
    case modern = "系统 17.4+ · 实验 USB"

    /// 通过 Xcode 操作已配对的局域网真机。
    case wireless = "已配对真机 · Wi-Fi"

    /// 直接更新接收端应用的蓝牙位置。
    case bluetooth = "手机应用 · 蓝牙直连"

    case iap2 = "配件定位 · iAP2 蓝牙"
    case reverseBluetooth = "蓝牙 · 手机扫描 Mac"
    var isBluetooth: Bool { self == .bluetooth || self == .reverseBluetooth }

    /// 启动页蓝牙入口涵盖经典配件与手机 App 的两个 BLE 方向。
    var usesBluetoothWorkspace: Bool { self == .iap2 || isBluetooth }

    /// USB 手机遥控按真机 UDID 寻址。
    var supportsUSBController: Bool { !isBluetooth && self != .iap2 && self != .simulator }

    /// 仅用于模拟器的端到端验证。
    case simulator = "iOS 模拟器"

    var recoveryScope: LocationRecoveryScope {
        switch self {
        case .bluetooth, .reverseBluetooth: return .bluetoothApp
        case .simulator: return .simulator
        default: return .device
        }
    }

    /// 在选择器中使用稳定的模式标识。
    var id: Self { self }
}

/// 一台真机在 Mac 控制台中的最新发现结果与会话回执，仅在主 actor 中更新。
struct DeviceSnapshot {
    /// 旧版模式最近发现了该设备；现代模式已手动确认目标标识。两者均非持续连接监测。
    var sessionVersion = UUID()
    var name: String?
    var transport: CoreDeviceLocationBackend.Transport?
    var transportLabel: String? { transport.map { $0 == .usb ? "USB" : "Wi-Fi" } }
    var observedPairing = false
    var isAvailable = false
    var bluetoothConnected = false
    var systemBluetoothConnected: Bool?

    /// App 连接由代理回调维护，系统连接来自最近一次扫描。
    var bluetoothLabel: String {
        if bluetoothConnected { return "控制台已连接" }
        guard isAvailable else { return "连接待确认" }
        if systemBluetoothConnected == true { return "系统已连接 · 控制台未连接" }
        return "已发现 · 控制台未连接"
    }
    /// 仅在系统枚举确认拔线时允许由同一手机重新握手恢复可用标记。
    var missingUSBCable = false
    /// 当前会话的回执级状态，不代表独立定位观测。
    var status: SessionStatus = .idle
    /// 最近一次命令的回执或状态变化描述。
    var feedback = "本次打开控制台后尚未向此设备发出命令。"
    /// 最近一次命令的可展示错误，nil 表示没有待显示的错误。
    var error: String?
}

/// 管理地图草稿、USB 设备发现与每台真机唯一的本机定位会话。
/// 所有可观察的状态均在主 actor 修改，实际设备命令由后端和会话 actor 执行。
@MainActor
final class MacConsoleModel: ObservableObject {
    private let inboundBluetooth = BluetoothHostPeripheral()
    private let bluetoothBackend = BluetoothLocationBackend()
    private let simulatorBackend = SimulatorLocationBackend()
    private let portableExecutable: URL?
    private let attachedDevices: @Sendable () async throws -> [PortableDevice]
    @Published private(set) var nearbyWarning: String?
    private var nearbyDevices: [PortableDevice] = []
    var usesPortableDiscovery: Bool { backendMode == .automatic && portableExecutable != nil }

    nonisolated static var bundledDeviceTool: URL? {
        let tool = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/DeviceLocation.app/Contents/MacOS/DeviceLocation")
        return FileManager.default.isExecutableFile(atPath: tool.path) ? tool : nil
    }

    private let automaticBackend: CoreDeviceLocationBackend
    @Published private(set) var scanningConnections = false
    private let wirelessBackend = CoreDeviceLocationBackend()
    private let wiredBackend = CoreDeviceLocationBackend(transport: .usb)
    private let legacyBackend = USBLocationBackend()
    private var modernBackends: [String: ModernLocationBackend] = [:]
    private var sessions: [String: DeviceSession] = [:]
    private var connectionGeneration = 0
    private var backendConfigurationGeneration = 0

    /// 注入设备工具以便验证自动发现及切换链路时的会话状态。
    init(automaticBackend: CoreDeviceLocationBackend = .init(transport: nil),
         portableExecutable: URL? = MacConsoleModel.bundledDeviceTool,
         attachedDevices: @escaping @Sendable () async throws -> [PortableDevice] = { try await PortableDevice.attached() }) {
        self.portableExecutable = portableExecutable
        self.attachedDevices = attachedDevices
        self.automaticBackend = automaticBackend
    }

    /// 当前地图草稿中的 WGS 84 纬度文本，使用句点作为小数分隔符，单位为度。
    @Published var latitudeText = ""
    /// 当前地图草稿中的 WGS 84 经度文本，使用句点作为小数分隔符，单位为度。
    @Published var longitudeText = ""
    /// 用户选中的设备标识；nil 表示尚未选择。
    @Published var selectedDeviceID: String?
    /// 默认通过 Xcode 发现已配对的 USB 和 Wi-Fi 真机，用户也可显式选择其他路径。
    @Published private(set) var backendMode = ConsoleBackendMode.automatic
    /// 现代模式选定的 Python 可执行文件，nil 表示尚未配置。
    @Published private(set) var modernPythonURL: URL?
    /// 现代模式待确认的目标标识，不是设备发现或配对凭据。
    @Published var manualDeviceID = ""
    /// 后端配置错误说明。
    @Published private(set) var configurationError: String?
    /// 按 USB 设备标识保存本次打开控制台后的发现和会话结果。
    @Published private(set) var devices: [String: DeviceSnapshot] = [:]
    /// 当前发现状态说明。
    @Published private(set) var discoveryFeedback = "正在等待识别已配对的设备。"
    /// 当前发现错误说明，nil 表示没有待显示的错误。
    @Published private(set) var discoveryError: String?
    /// 当前执行中的操作说明，nil 表示没有操作在等待后端。
    @Published private(set) var activity: String?
    /// 主机休眠等连接失效事件的异步会话处理是否仍在进行。
    @Published private(set) var isInvalidatingConnections = false

    /// 本次打开控制台后已发现过的设备标识，包含暂时未连接的设备。
    var deviceIDs: [String] { devices.keys.sorted() }

    /// 当前选中设备的快照；未选择时返回 nil。
    var selectedDevice: DeviceSnapshot? {
        guard let deviceID = selectedDeviceID else { return nil }
        return devices[deviceID]
    }

    /// 草稿通过域模型校验后的不可变坐标；空白或无效输入返回 nil。
    var draftPoint: GeoPoint? { try? validatedDraft() }

    /// 坐标不完整或校验失败时的用户可见描述，草稿为空时不提示错误。
    var draftError: String? {
        if latitudeText.isEmpty && longitudeText.isEmpty { return nil }
        do {
            _ = try validatedDraft()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 刷新、设点、清除或连接失效处理进行时，禁止再次发起命令以及切换目标设备。
    var isBusy: Bool { activity != nil || isInvalidatingConnections }

    /// 切换后端模式会重建空闲会话，仅当所有设备均无活动或未知会话时允许。
    var canChangeBackendMode: Bool { !isBusy && devices.values.allSatisfy { $0.status == .idle } }

    /// 修改现代 Python 路径不会销毁现有会话；只有无命令在执行时允许配置。
    var canChangePython: Bool { !isBusy && backendMode == .modern }

    /// 现代模式的目标标识输入经格式校验之后才可加入列表，仍必须由用户自行确认设备及连接。
    var canAddManualTarget: Bool {
        !isBusy && backendMode == .modern && modernPythonURL != nil &&
            ModernHelperResource.scriptURL != nil && hasValidManualDeviceID
    }

    /// 统一 ASCII UDID 大小写，避免同一设备建立多个会话；实际标识由 helper 校验。
    private var normalizedManualDeviceID: String {
        manualDeviceID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// UDID 为空或格式不符合已支持的 USB 标识形式时，不允许加入列表。
    private var hasValidManualDeviceID: Bool {
        let id = normalizedManualDeviceID
        return id.range(of: "^(?:[0-9a-f]{40}|[0-9a-f]{8}-[0-9a-f]{16})$",
                        options: .regularExpression) == id.startIndex..<id.endIndex
    }

    /// 仅允许向最近一次发现的设备清除位置；结果未知时也可主动清除。
    var canClear: Bool {
        selectedDevice?.isAvailable == true && !isBusy &&
            (!backendMode.isBluetooth || BluetoothPointCommand.validCode(bluetoothCode))
    }

    /// 接收码按目标分开保存，仅用于当前蓝牙模式。
    var bluetoothCode: String {
        get {
            guard let id = selectedDeviceID else { return "" }
            return backendMode == .reverseBluetooth ? inboundBluetooth.codes[id] ?? "" : bluetoothBackend.code(for: id)
        }
        set {
            guard backendMode.isBluetooth, !isBusy, let id = selectedDeviceID else { return }
            objectWillChange.send()
            if backendMode == .reverseBluetooth { inboundBluetooth.codes[id] = newValue }
            else { bluetoothBackend.setCode(newValue, for: id) }
        }
    }

    /// 草稿可执行且设备状态非未知时允许应用；未知状态须先收到清除回执。
    var canApply: Bool {
        canClear && draftPoint != nil && selectedDevice?.status != .unknown &&
            (!backendMode.isBluetooth || selectedDevice?.bluetoothConnected == true)
    }

    /// 解析当前草稿，并统一通过 ScenarioKit 校验 WGS 84 坐标。
    /// - Returns: 不可变、已校验的纬度和经度，单位为度。
    /// - Throws: 文本无法转为数值或 GeoPoint 校验失败。
    private func validatedDraft() throws -> GeoPoint {
        guard let latitude = Double(latitudeText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let longitude = Double(longitudeText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DraftError.invalidNumber
        }
        return try GeoPoint(latitude: latitude, longitude: longitude)
    }

    /// 地图选点只修改草稿，不发出设备命令。
    /// - Parameter coordinate: MapKit 提供的 WGS 84 经纬度，单位为度；无效坐标不改变草稿。
    func selectMapPoint(_ coordinate: CLLocationCoordinate2D) {
        guard let point = try? GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude) else {
            return
        }
        latitudeText = String(point.latitude)
        longitudeText = String(point.longitude)
    }

    /// 输入改变后清除上一次按地址查询的结论。
    @Published var wirelessAddress = "" {
        didSet {
            guard oldValue != wirelessAddress else { return }
            if selectedDeviceID == checkedWirelessID { selectedDeviceID = nil }
            checkedWirelessID = nil
            wirelessCheck = nil
        }
    }
    @Published private(set) var wirelessCheck: String?
    private var checkedWirelessID: String?

    /// 按 IP 核对当前无线设备的身份及开发服务，成功后选中该目标。
    func checkWirelessAddress() async {
        guard backendMode == .wireless, !isBusy else { return }
        let address = wirelessAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedDeviceID = nil
        checkedWirelessID = nil
        discoveryError = nil
        discoveryFeedback = "请通过 IP 验证或在列表中选择无线设备。"
        guard WirelessDeviceAddress.bytes(address) != nil else {
            wirelessCheck = "请输入有效的 IPv4 或 IPv6 地址。"
            return
        }
        let generation = connectionGeneration
        activity = "正在核对无线设备…"
        wirelessCheck = nil
        defer { activity = nil }
        do {
            let id = try await WirelessDeviceAddress.deviceID(at: address)
            let target = try await wirelessBackend.verifyWirelessDevice(id: id)
            guard generation == connectionGeneration, address == wirelessAddress.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            registerTarget(target.id, backend: wirelessBackend)
            devices[target.id]?.name = target.name
            devices[target.id]?.isAvailable = true
            selectedDeviceID = target.id
            checkedWirelessID = target.id
            discoveryError = nil
            discoveryFeedback = "已选中通过 IP 验证的无线设备。"
            wirelessCheck = "本次已连接 · " + target.name + " · " + address
        } catch {
            guard generation == connectionGeneration, address == wirelessAddress.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            wirelessCheck = "未确认连接 · " + address + " · " + error.localizedDescription
        }
    }

    /// 查找已配对的 Bonjour 设备；缓慢的局域网浏览独立于 USB 枚举。
    func refreshNearbyDevices() async {
        guard usesPortableDiscovery, let portableExecutable else { return }
        let generation = backendConfigurationGeneration
        do {
            let data = try await ModernLocationBackend.discoverPeers(using: portableExecutable)
            struct Report: Decodable { let devices: [PortableDevice]; let warning: String? }
            let report = try JSONDecoder().decode(Report.self, from: data)
            guard !Task.isCancelled, generation == backendConfigurationGeneration else { return }
            nearbyDevices = report.devices
            nearbyWarning = report.warning
        } catch {
            guard !Task.isCancelled, generation == backendConfigurationGeneration else { return }
            nearbyDevices = []
            nearbyWarning = "无法查询 Wi-Fi 设备 · " + error.localizedDescription
        }
    }

    /// 由用户对已选 USB 设备发起信任请求并启用系统的无线连接设置。
    func prepareSelectedWiFi() async {
        guard usesPortableDiscovery, let portableExecutable, !isBusy,
              let id = selectedDeviceID, selectedDevice?.transport == .usb, selectedDevice?.isAvailable == true else { return }
        activity = "请解锁 iPhone 并确认信任此电脑…"
        defer { activity = nil }
        do {
            try await ModernLocationBackend.prepareWiFi(using: portableExecutable, device: id)
            devices[id]?.feedback = "设备已确认 Wi-Fi 连接设置。请保持同一局域网，然后拔线。"
            devices[id]?.error = nil
        } catch {
            devices[id]?.error = "配对或启用 Wi-Fi 失败 · " + error.localizedDescription
        }
    }

    /// 刷新当前模式的设备列表。如发现失败或刷新后某个设备缺失，撤销其当前可用标记并检查会话。
    /// 自动扫描期间仍可选择设备；丢弃过期扫描，避免覆盖用户操作。
    func refreshDevices() async {
        guard !isBusy, !scanningConnections, backendMode != .modern else { return }
        let automatic = backendMode == .automatic
        let configuration = backendConfigurationGeneration
        let versions = devices.mapValues(\.sessionVersion)
        wirelessCheck = nil
        if automatic { scanningConnections = true } else { activity = "正在刷新目标设备…" }
        discoveryError = nil
        let generation = connectionGeneration
        defer {
            if automatic { scanningConnections = false } else { activity = nil }
        }
        // 后台发现期间用户仍可选择设备和设点，较早的扫描结果不能覆盖新命令。
        func currentScan() -> Bool {
            !Task.isCancelled && configuration == backendConfigurationGeneration &&
                generation == connectionGeneration && (!automatic || !isBusy)
        }

        do {
            let backend: (any LocationBackend)?
            let ids: [String]
            var names: [String: String] = [:]
            var transports: [String: CoreDeviceLocationBackend.Transport] = [:]
            var systemLinks: [String: Bool] = [:]
            switch backendMode {
            case .automatic where usesPortableDiscovery:
                backend = nil
                var local: [PortableDevice] = []
                do { local = try await attachedDevices() }
                catch {
                    guard currentScan() else { return }
                    discoveryError = "无法读取系统 USB 设备列表 · " + error.localizedDescription
                }
                let rows = nearbyDevices.filter(\.network) + local
                for row in local + nearbyDevices {
                    if let name = row.name { names[row.key] = name }
                }
                for row in rows where transports[row.key] != .usb {
                    transports[row.key] = row.network ? .wifi : .usb
                }
                ids = Array(transports.keys)
            case .automatic, .wireless, .wired:
                let core = automatic ? automaticBackend : (backendMode == .wired ? wiredBackend : wirelessBackend)
                backend = core
                let targets = try await core.devices()
                let knownIDs = Dictionary(deviceIDs.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
                for target in targets {
                    let id = knownIDs[target.id.lowercased()] ?? target.id
                    transports[id] = target.transport
                    names[id] = [target.name, target.version].compactMap { $0 }.joined(separator: " · ")
                }
                ids = Array(transports.keys)
            case .bluetooth:
                backend = bluetoothBackend
                let targets = try await bluetoothBackend.devices()
                for target in targets {
                    names[target.id] = target.name
                    systemLinks[target.id] = target.systemConnected
                }
                ids = targets.map(\.id)
            case .simulator:
                backend = simulatorBackend
                ids = try await simulatorBackend.devices()
            case .legacy:
                backend = legacyBackend
                ids = try await legacyBackend.devices()
            case .modern, .reverseBluetooth, .iap2:
                return
            }
            let discovered = Set(ids)
            guard currentScan() else { return }
            for id in discovered {
                guard !automatic || devices[id]?.sessionVersion == versions[id] else { continue }
                if usesPortableDiscovery, let portableExecutable {
                    if sessions[id] == nil {
                        let portable = ModernLocationBackend(executable: portableExecutable, transport: nil) { [weak self] in
                            Task { @MainActor in
                                guard let self, configuration == self.backendConfigurationGeneration else { return }
                                await self.markUnavailable(id)
                            }
                        }
                        registerTarget(id, backend: portable)
                    }
                } else if let backend {
                    registerTarget(id, backend: backend)
                }
                devices[id]?.name = names[id] ?? (usesPortableDiscovery ? devices[id]?.name ?? "移动设备" : nil)
                devices[id]?.observedPairing = usesPortableDiscovery && nearbyDevices.contains(where: { $0.key == id })
                devices[id]?.transport = transports[id]
                devices[id]?.systemBluetoothConnected = systemLinks[id]
            }

            for id in deviceIDs {
                guard currentScan() else { return }
                if automatic, let version = versions[id], devices[id]?.sessionVersion != version { continue }
                if discovered.contains(id) || devices[id]?.bluetoothConnected == true {
                    devices[id]?.isAvailable = true
                    devices[id]?.missingUSBCable = false
                } else if devices[id]?.isAvailable == true {
                    await markUnavailable(id)
                }
                guard currentScan() else { return }
            }
            if discovered.isEmpty {
                switch backendMode {
                case .automatic where usesPortableDiscovery:
                    discoveryFeedback = "尚未识别到设备。首次请用数据线连接，解锁 iPhone 并允许配件连接。"
                case .automatic:
                    discoveryFeedback = "未发现已配对的设备。请解锁 iPhone，通过数据线连接，或确认已配对的无线设备与 Mac 在同一局域网。"
                case .wired:
                    discoveryFeedback = "Xcode 未列出可用的已配对 USB 真机。请用数据线连接并解锁 iPhone，在 Xcode 的设备窗口确认配对状态后刷新。如果访达通过 Wi-Fi 显示手机，请切换到 Wi-Fi 模式。"
                case .wireless:
                    discoveryFeedback = "Xcode 未列出可用的已配对 Wi-Fi 真机。请确认设备与 Mac 在同一局域网；如果仍插着数据线，可先切换到 USB 自动并刷新。"
                case .bluetooth:
                    discoveryFeedback = "未扫描到定位接收端。请在 iPhone 应用中开启蓝牙接收，保持前台后重新扫描。"
                default:
                    discoveryFeedback = "本次刷新未发现可用目标。"
                }
            } else {
                discoveryFeedback = "本次刷新发现 \(discovered.count) 台设备；连接状态以最近一次刷新为准。"
            }
        } catch {
            guard currentScan() else { return }
            discoveryFeedback = "本次刷新失败，无法确认设备可用性。"
            discoveryError = error.localizedDescription
            for id in deviceIDs where devices[id]?.isAvailable == true {
                guard currentScan() else { return }
                if automatic, devices[id]?.sessionVersion != versions[id] { continue }
                await markUnavailable(id)
            }
        }
    }

    /// 显式广播供手机订阅的服务；订阅与断线只更新对应手机的可用性。
    func advertiseBluetooth() {
        guard backendMode == .reverseBluetooth else { return }
        inboundBluetooth.onStatus = { [weak self] text in self?.discoveryFeedback = text }
        inboundBluetooth.onPeer = { [weak self] id, connected in
            guard let self, backendMode == .reverseBluetooth else { return }
            if connected {
                registerTarget(id, backend: inboundBluetooth)
                devices[id]?.name = "蓝牙手机 · " + id.suffix(6)
                devices[id]?.isAvailable = true
                updateBluetoothConnection(true, for: id)
                if selectedDeviceID == nil { selectedDeviceID = id }
                discoveryFeedback = "手机已连接。请输入手机显示的六位接收码。"
            } else {
                devices[id]?.isAvailable = false
                updateBluetoothConnection(false, for: id)
                Task {
                    guard self.backendMode == .reverseBluetooth, self.devices[id]?.isAvailable == false else { return }
                    await self.markUnavailable(id)
                }
            }
        }
        inboundBluetooth.start()
    }

    /// 显式连接仅验证接收服务；用户可先检查链路，再输入接收码设点。
    func connectBluetooth() async {
        guard backendMode == .bluetooth, !isBusy, let id = selectedDeviceID,
              devices[id]?.isAvailable == true, devices[id]?.bluetoothConnected == false else { return }
        let generation = connectionGeneration
        activity = "正在连接手机并检查定位接收服务…"
        discoveryError = nil
        defer { activity = nil }
        do {
            try await bluetoothBackend.connect(id) { [weak self] in
                guard let self, self.backendMode == .bluetooth else { return }
                self.updateBluetoothConnection(false, for: id)
                self.devices[id]?.systemBluetoothConnected = nil
                self.devices[id]?.isAvailable = false
                self.discoveryFeedback = "手机连接已断开，请开启蓝牙接收后重新扫描。"
                Task { @MainActor in
                    guard self.backendMode == .bluetooth, self.devices[id]?.isAvailable == false else { return }
                    await self.markUnavailable(id)
                }
            }
            guard generation == connectionGeneration else { return }
            updateBluetoothConnection(true, for: id)
            discoveryFeedback = "定位接收服务已连接。输入手机接收码后即可设点。"
        } catch {
            guard generation == connectionGeneration else { return }
            discoveryError = error.localizedDescription
        }
    }

    /// 链路变化立即更新发送门禁，并使旧连接上弹出的发送确认失效。
    func updateBluetoothConnection(_ connected: Bool, for id: String) {
        guard devices[id]?.bluetoothConnected != connected else { return }
        devices[id]?.bluetoothConnected = connected
        devices[id]?.sessionVersion = UUID()
    }

    /// 只释放本应用持有的链路；设备仍可在后续定位操作时按需重连。
    func disconnectBluetooth() {
        guard backendMode == .bluetooth, !isBusy, let id = selectedDeviceID else { return }
        bluetoothBackend.disconnect(id)
        updateBluetoothConnection(false, for: id)
        devices[id]?.systemBluetoothConnected = nil
        discoveryFeedback = "控制台已断开连接。可重新扫描以更新系统连接状态。"
    }

    /// 切换后端模式，仅舍弃空闲会话及其历史回执，不遗失活动或未知会话。
    /// - Parameter mode: 用户选择的 USB 实验后端。
    func changeBackendMode(_ mode: ConsoleBackendMode) {
        guard canChangeBackendMode, mode != backendMode else { return }
        backendConfigurationGeneration += 1
        inboundBluetooth.stop()
        bluetoothBackend.disconnectAll()
        bluetoothBackend.forgetCodes()
        wirelessCheck = nil
        nearbyDevices = []
        nearbyWarning = nil
        backendMode = mode
        devices.removeAll()
        sessions.removeAll()
        modernBackends.removeAll()
        selectedDeviceID = nil
        manualDeviceID = ""
        configurationError = nil
        discoveryError = nil
        switch mode {
        case .bluetooth: discoveryFeedback = "等待扫描手机 App。"
        case .reverseBluetooth: discoveryFeedback = "等待开启 Mac 蓝牙广播。"
        case .modern: discoveryFeedback = "请输入目标设备 UDID；此模式不自动发现设备。"
        default: discoveryFeedback = "请刷新目标设备。"
        }
    }

    /// 更新现代模式后续启动 helper 时使用的 Python 可执行文件。
    /// 不会替换现有活动 helper，也不会清除会话门禁；未知状态仍须明确清除。
    /// - Parameter url: 用户通过系统文件选择器指定的已安装解释器 URL。
    func changePythonURL(_ url: URL) async {
        guard canChangePython else { return }
        guard let scriptURL = ModernHelperResource.scriptURL else {
            configurationError = "未找到内置的现代 USB helper 资源。"
            return
        }
        var isDirectory: ObjCBool = false
        guard url.isFileURL,
              FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) else {
            configurationError = "请选择本机已有的可执行 Python 文件。"
            return
        }
        configurationError = nil
        activity = "正在更新现代 USB 后端配置…"
        defer { activity = nil }

        // 保留各台设备的调试会话和正在运行的 helper；新路径仅影响后续启动。
        var failures: [String] = []
        for (id, backend) in modernBackends {
            do {
                try await backend.updatePaths(pythonURL: url, scriptURL: scriptURL)
            } catch {
                failures.append("\(id)：\(error.localizedDescription)")
            }
        }
        if failures.isEmpty {
            modernPythonURL = url
        } else {
            configurationError = "部分设备路径更新失败；请重新选择可用的解释器。\n" + failures.joined(separator: "\n")
        }
    }

    /// 在现代模式添加或重新确认用户输入的目标设备标识。
    /// 同一设备继续使用原有会话协调器，包括未知状态，不自动重放设点请求。
    func addManualTarget() async {
        guard canAddManualTarget, let pythonURL = modernPythonURL,
              let scriptURL = ModernHelperResource.scriptURL else { return }
        let id = normalizedManualDeviceID
        let generation = backendConfigurationGeneration
        let revision = connectionGeneration
        activity = "正在核对 USB 连接…"
        defer { activity = nil }
        let attached = try? await attachedDevices()
        guard backendConfigurationGeneration == generation, connectionGeneration == revision,
              normalizedManualDeviceID == id else { return }
        guard attached?.contains(where: { !$0.network && $0.key == id }) == true else {
            if devices[id]?.isAvailable == true { await markUnavailable(id) }
            discoveryError = attached == nil ? "无法读取 USB 连接，请检查数据线后重试。" : "未连接该 UDID 对应的 USB 设备。"
            return
        }
        discoveryError = nil
        if sessions[id] == nil {
            let backend = ModernLocationBackend(pythonURL: pythonURL, scriptURL: scriptURL) { [weak self] in
                Task { @MainActor in
                    guard let self, self.backendConfigurationGeneration == generation else { return }
                    await self.markUnavailable(id)
                }
            }
            modernBackends[id] = backend
            registerTarget(id, backend: backend)
        }
        devices[id]?.isAvailable = true
        selectedDeviceID = id
        discoveryFeedback = "已核对 USB 连接，可以发送地图选点。"
    }

    /// 实验 USB 模式只更新已验证过的目标；拔线撤销发送资格，重连须重新确认。
    func refreshManualConnections() async {
        guard backendMode == .modern, !isBusy else { return }
        let available = devices.filter { $0.value.isAvailable }.mapValues(\.sessionVersion)
        guard !available.isEmpty else { return }
        let generation = connectionGeneration
        let rows = (try? await attachedDevices()) ?? []
        let connected = Set(rows.filter { !$0.network }.map(\.key))
        for (id, version) in available where !connected.contains(id) {
            guard backendMode == .modern, generation == connectionGeneration, !isBusy else { return }
            if devices[id]?.sessionVersion == version { await markUnavailable(id, missingCable: true) }
        }
    }

    /// 注册已发现或手动确认的目标，共享唯一的执行协调器；重复注册保留原会话。
    func registerTarget(_ id: String, backend: any LocationBackend) {
        guard sessions[id] == nil else { return }
        sessions[id] = DeviceSession(deviceID: id, backend: backend)
        devices[id] = DeviceSnapshot(isAvailable: true)
    }

    /// 将单台已知设备标记为未确认连接；若仍可能有活动模拟位置，则请求会话标记结果未知。
    /// - Parameter id: 本次打开控制台后记录过的设备标识。
    private func markUnavailable(_ id: String, missingCable: Bool = false) async {
        guard let session = sessions[id] else { return }
        let generation = backendConfigurationGeneration
        bluetoothBackend.disconnect(id)
        updateBluetoothConnection(false, for: id)
        devices[id]?.systemBluetoothConnected = nil
        devices[id]?.isAvailable = false
        devices[id]?.missingUSBCable = missingCable
        devices[id]?.sessionVersion = UUID()
        await session.markDisconnected()
        let status = await session.status
        guard generation == backendConfigurationGeneration else { return }
        devices[id]?.status = status
        if status == .unknown {
            devices[id]?.feedback = "连接无法确认，设备结果未知。重新连接后请先清除；不会自动重发设点。"
        }
    }

    /// usbmuxd 成功枚举后确认目标缺失或连接编号变化；活动会话进入待清除状态。
    func usbCableLost(_ id: String) async {
        guard backendMode.supportsUSBController, backendMode != .wireless,
              (backendMode != .automatic || devices[id]?.transport == .usb), devices[id]?.isAvailable == true else { return }
        await markUnavailable(id, missingCable: true)
    }

    /// 同一 USB 目标的配对手机返回前台，只恢复连接标志，保留未知会话及其清除门禁。
    func confirmUSBController(_ id: String) {
        guard !isInvalidatingConnections, backendMode.supportsUSBController,
              devices[id]?.missingUSBCable == true else { return }
        devices[id]?.missingUSBCable = false
        devices[id]?.isAvailable = true
    }

    /// 在主机即将休眠时使连接发现结果失效，并通知各会话。
    /// 若此时已有操作正在等待回执，会话协调器继续保留命令门禁；恢复后不会自动重发旧命令。
    func invalidateConnectionsForSleep() async {
        guard !isInvalidatingConnections else { return }
        isInvalidatingConnections = true
        nearbyDevices = []
        wirelessCheck = nil
        connectionGeneration += 1
        inboundBluetooth.stop()
        bluetoothBackend.disconnectAll()
        discoveryFeedback = backendMode != .modern
            ? "检测到 Mac 休眠，连接需重新刷新。"
            : "检测到 Mac 休眠，请重新确认手动输入的目标设备。"
        discoveryError = nil
        for id in deviceIDs { devices[id]?.isAvailable = false }
        defer { isInvalidatingConnections = false }
        for id in deviceIDs { await markUnavailable(id) }
    }

    /// 将调用时的草稿复制为不可变坐标并应用到当前用户选定的设备。
    /// 在主 actor 更新界面状态，异步等待会话回执；后续编辑草稿不会更改本次命令。
    /// 失败及取消保存为会话返回的状态和可展示错误，不推断真机位置。
    @discardableResult
    func applyDraft() async -> GeoPoint? {
        guard canApply, let id = selectedDeviceID, let point = draftPoint else { return nil }
        return await execute(point, on: id) ? point : nil
    }

    /// 在主 actor 捕获当前选择；清除回执仍需独立定位观测确认。
    func clearSelectedDevice() async {
        guard canClear, let id = selectedDeviceID else { return }
        await execute(nil, on: id)
    }

    /// 确认框展示期间其他控制端可能更换位置，恢复前复核原设备及会话版本。
    func restore(_ target: RemoteTarget) async {
        guard selectedDeviceID == target.id, selectedDevice?.sessionVersion == target.session, canClear else {
            discoveryError = "目标设备或会话已变化，请重新选择设备并确认恢复。"
            return
        }
        discoveryError = nil
        await execute(nil, on: target.id)
    }

    /// 返回所有已配置设备最近一次检查结果，手机必须明确选中其中一台。
    var remoteTargets: [RemoteTarget] {
        deviceIDs.compactMap { id in
            guard let target = devices[id] else { return nil }
            let link: String
            if !target.isAvailable { link = "连接待重新确认" }
            else if let transport = target.transportLabel { link = transport + " · " + (target.name ?? id) }
            else if backendMode == .wireless { link = "Wi-Fi · " + (target.name ?? id) }
            else if backendMode.isBluetooth { link = "蓝牙 · 手机应用位置" }
            else if backendMode == .wired { link = "USB · " + (target.name ?? id) }
            else if backendMode == .modern { link = "已核对 USB 连接" }
            else { link = "最近一次已发现目标" }
            return RemoteTarget(id: id, session: target.sessionVersion, available: target.isAvailable && (!backendMode.isBluetooth || target.bluetoothConnected),
                                needsClear: target.status == .unknown,
                                detail: [link, target.error ?? target.feedback].joined(separator: " · "),
                                recoveryScope: backendMode.recoveryScope, hasActiveLocation: target.status != .idle)
        }
    }

    /// 验证远端不可变请求并通过桌面端的同一个会话执行。过期、旧会话或未配置设备均不发令。
    func handleRemote(_ request: RemoteRequest) async -> RemoteReply {
        func reply(_ phase: RemoteReply.Phase, _ message: String) -> RemoteReply {
            RemoteReply(request, phase, message, targets: remoteTargets)
        }
        guard (0...60).contains(request.expires.timeIntervalSinceNow) else {
            return reply(.rejected, "请求已过期或两端时钟不同步。")
        }
        if request.action == .status { return reply(.status, "Mac 已连接。") }
        guard let id = request.device, let device = devices[id], device.isAvailable,
              device.sessionVersion == request.session else {
            return reply(.rejected, "目标设备或会话已变化，请核对最新状态后重新提交。")
        }
        guard !isBusy else { return reply(.rejected, "Mac 正在处理其他操作。") }
        let point: GeoPoint?
        if request.action == .apply {
            guard !backendMode.isBluetooth || device.bluetoothConnected else { return reply(.rejected, "请先连接手机的蓝牙接收服务。") }
            guard device.status != .unknown else { return reply(.rejected, "请先清除结果未知的会话。") }
            guard let lat = request.latitude, let lon = request.longitude,
                  let valid = try? GeoPoint(latitude: lat, longitude: lon) else {
                return reply(.rejected, "坐标无效。")
            }
            point = valid
        } else { point = nil }
        await execute(point, on: id)
        guard let result = devices[id] else { return reply(.unknown, "目标状态未知。") }
        if result.status == .unknown { return reply(.unknown, result.error ?? result.feedback) }
        if let error = result.error { return reply(.rejected, error) }
        return reply(.accepted, result.feedback)
    }

    /// 桌面与远端共用的命令入口。进入等待前轮换会话版本，后续草稿和选择不会改变执行目标。
    /// - Parameters:
    ///   - point: WGS 84 坐标（度），nil 表示显式清除。
    ///   - id: 已通过调用方门禁的设备标识。
    @discardableResult
    private func execute(_ point: GeoPoint?, on id: String) async -> Bool {
        guard let session = sessions[id], devices[id]?.isAvailable == true else { return false }
        guard point == nil || !backendMode.isBluetooth || devices[id]?.bluetoothConnected == true else { return false }
        let clearing = point == nil
        devices[id]?.sessionVersion = UUID()
        activity = clearing ? "正在清除模拟位置…" : "正在应用固定位置…"
        devices[id]?.status = clearing ? .clearing : .applying
        devices[id]?.feedback = "命令已送达 Mac，等待工具回执。"
        devices[id]?.error = nil
        let generation = connectionGeneration
        defer { activity = nil }
        do {
            if backendMode == .modern, point != nil {
                let usb = try await attachedDevices()
                guard generation == connectionGeneration, usb.contains(where: { !$0.network && $0.key == id }) else {
                    throw DeviceConnectionLostError("USB 连接已失效，请重新连接设备。")
                }
            }
            let feedback: String
            if let point {
                let sent = try await session.applyWithReceipt(point)
                let accepted = backendMode.isBluetooth ? "手机已确认更新 Everywhere 地图标记。系统模拟定位请使用 USB 或 Wi-Fi 真机后端。" : "设点工具已成功返回；请在 Everywhere 的“诊断”中确认新位置。"
                feedback = sent ? accepted : "同一点刚收到后端回执，本次未重复发送。"
            } else {
                try await session.clear()
                feedback = backendMode.recoveryScope.receipt
            }
            if generation != connectionGeneration { await session.markDisconnected() }
            let status = await session.status
            devices[id]?.status = status
            devices[id]?.feedback = status == .unknown ? "执行期间连接发生变化，设备结果未知。"
                : feedback
            return status != .unknown
        } catch {
            await recordOperationFailure(error, deviceID: id, session: session, isClearing: clearing)
            return false
        }
    }

    /// 将会话失败同步到设备快照；已观察到失联时同时使连接失效，不沿用旧的可用标记。
    /// - Parameters:
    ///   - error: 会话 actor 抛出的执行或前置检查错误。
    ///   - deviceID: 发出请求时的目标设备标识，而非之后的界面选择。
    ///   - session: 对应目标设备的会话 actor。
    ///   - isClearing: 本次命令是否为清除，用于显示回执说明。
    private func recordOperationFailure(_ error: Error, deviceID: String, session: DeviceSession,
                                        isClearing: Bool) async {
        if error is DeviceConnectionLostError {
            await markUnavailable(deviceID)
            discoveryFeedback = backendMode != .modern
                ? "目标连接已失效，请重新连接并刷新设备。"
                : "目标 USB 连接已失效，请重新连接并确认目标。"
        } else {
            let status = await session.status
            devices[deviceID]?.status = status
            if error is BackendPreflightError {
                devices[deviceID]?.feedback = isClearing
                    ? "工具确认本次清除命令尚未发送，之前的会话仍须处理。"
                    : "工具确认本次设点命令尚未发送，请检查配置与连接。"
            } else {
                devices[deviceID]?.feedback = isClearing
                    ? "清除未取得成功回执，请检查当前会话状态。"
                    : "设点未取得成功回执，请检查当前会话状态。"
            }
        }
        var message = error.localizedDescription
        if isClearing {
            if error is DeviceConnectionLostError {
                message += " 请重新连接同一目标并刷新，然后再次执行恢复。"
            } else if !(error is BackendPreflightError) {
                message += " 恢复结果未确认，请核对目标状态后重试。"
            }
        }
        devices[deviceID]?.error = message
    }

    /// 控制台文本输入无法解析成数字时的错误。
    private enum DraftError: LocalizedError {
        case invalidNumber

        var errorDescription: String? { "请输入有效的纬度和经度，小数点使用句点。" }
    }
}
