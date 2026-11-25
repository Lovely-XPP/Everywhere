import Foundation
import Network
import SwiftUI
#if SWIFT_PACKAGE
import RemoteControl
import ScenarioKit
#endif

/// 手机只提交选点快照。Mac 的后端回执与两段连接分别展示，手机离线不会发送自动清除。
@MainActor
final class MobileModel: ObservableObject {
    private let preferences: UserDefaults
    private let loadKey: (String) throws -> String?
    private let storeKey: (String?, String) throws -> Void

    /// 默认读写系统钥匙串，端到端测试可以使用独立的内存凭据。
    init(loadKey: @escaping (String) throws -> String? = RemotePairing.load,
         storeKey: @escaping (String?, String) throws -> Void = RemotePairing.save,
         preferences: UserDefaults = .standard) {
        self.preferences = preferences
        address = preferences.string(forKey: "mobile.mac.address") ?? ""
        port = preferences.string(forKey: "mobile.mac.port") ?? String(RemotePairing.networkPort)
        self.loadKey = loadKey
        self.storeKey = storeKey
    }

    private func saveKey(_ value: String?, account: String) throws { try storeKey(value, account) }

    /// Mac 已在当前连接中验证的本机，旧版主机无法提供此字段。
    @Published private(set) var boundDevice: String?
    @Published private(set) var bindingMessage = ""
    private var bindingAccount: String?

    /// 控制指令的传输方式；定位会话始终归 Mac 管理。
    enum Transport: String, CaseIterable { case wifi = "Wi-Fi", usb = "USB", bluetooth = "蓝牙" }
    @Published private(set) var transport: Transport = .wifi
    @Published private(set) var usbListening = false
    private var usbListener: NWListener?
    private var resumeUSB = false
    @Published private(set) var hosts: [String: NWEndpoint] = [:]
    @Published private(set) var targets: [RemoteTarget] = []
    static let manual = "手动输入地址"
    @Published var address: String
    @Published var port: String
    @Published var selectedHost = MobileModel.manual
    @Published var code = ""
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var linkStatus = "请选择 Mac"
    @Published private(set) var discoveryMessage = ""
    @Published private(set) var receipt = ""
    private var browser: NWBrowser?
    private var link: RemoteLink?
    private var refresh: Task<Bool, Never>?
    private var polling: Task<Void, Never>?
    private var requestInFlight: UUID?
    private var pendingChange = false
    private var resumeHost: String?
    private let queue = DispatchQueue(label: "VirtualLocation.remote.mobile")

    var target: RemoteTarget? { targets.first { $0.id == boundDevice } }

    /// 首选 Bonjour；隔离组播的网络可明确输入主机地址及面板所示端口，认证要求相同。
    var endpoint: NWEndpoint? {
        if selectedHost == Self.manual {
            let host = manualHost
            guard !host.isEmpty, !host.contains("/"), !host.contains(where: { $0.isWhitespace }), let value = RemotePairing.parsePort(port),
                  let port = NWEndpoint.Port(rawValue: value) else { return nil }
            return .hostPort(host: NWEndpoint.Host(host), port: port)
        }
        return hosts[selectedHost]
    }

    /// 支持 IPv6 地址常用的方括号写法，端口由独立字段提供。
    private var manualHost: String {
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") { return String(host.dropFirst().dropLast()) }
        return host
    }

    private var account: String {
        if transport == .usb { return "usb:paired-host" }
        return selectedHost == Self.manual ? "endpoint:[\(manualHost.lowercased())]:\(port)" : selectedHost
    }

    /// 切换接口会终止当前手机控制连接，清除旧目标选择；后端不受影响。
    func chooseTransport(_ value: Transport) {
        guard value != transport else { return }
        disconnect()
        resumeUSB = false
        resumeHost = nil
        browser?.cancel()
        browser = nil
        hosts = [:]
        targets = []
        code = ""
        transport = value
        if value == .wifi { browse() } else { linkStatus = value == .usb ? "等待开启 USB 连接" : "蓝牙直连接收" }
    }

    /// 浏览本地网络。前台恢复后可重连已选且仍受信任的主机，仅刷新状态。
    func restartDiscovery() {
        browser?.cancel()
        browser = nil
        hosts.removeAll()
        discoveryMessage = "正在搜索局域网 Mac…"
        browse()
    }

    func browse() {
        guard transport != .bluetooth else { return }
        if transport == .usb {
            if resumeUSB { resumeUSB = false; connect() }
            return
        }
        if resumeHost == Self.manual && selectedHost == Self.manual { resumeHost = nil; connect() }
        guard browser == nil else { return }
        let search = NWBrowser(for: .bonjour(type: RemotePairing.service, domain: nil), using: .tcp)
        browser = search
        search.browseResultsChangedHandler = { [weak self, weak search] results, _ in
            Task { @MainActor in
                guard let self, let search, self.browser === search else { return }
                var found: [String: NWEndpoint] = [:]
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint { found[name] = result.endpoint }
                }
                self.hosts = found
                self.discoveryMessage = found.isEmpty ? "未发现局域网主机，可手动输入 Mac 的域名或 IP。" : ""
                if let name = self.resumeHost, self.selectedHost == name, found[name] != nil {
                    self.resumeHost = nil
                    self.connect()
                }
            }
        }
        search.stateUpdateHandler = { [weak self, weak search] state in
            Task { @MainActor in
                guard let self, let search, self.browser === search else { return }
                switch state {
                case .waiting(let error), .failed(let error):
                    self.discoveryMessage = "无法发现 Mac，请检查本地网络权限。\(error.localizedDescription)"
                    if case .failed = state { self.browser = nil; search.cancel() }
                default: break
                }
            }
        }
        search.start(queue: queue)
    }

    /// 切至后台时只撤销手机连接，恢复时不重放任何写操作。
    func background() {
        resumeUSB = transport == .usb && usbListening
        resumeHost = transport == .wifi && connected ? selectedHost : nil
        browser?.cancel()
        browser = nil
        disconnect()
        hosts.removeAll()
    }

    /// 改选主机会丢弃上一主机的目标、凭据输入和回执。
    func chooseHost(_ name: String) {
        disconnect()
        resumeHost = nil
        selectedHost = name
        code = ""
        receipt = ""
    }

    /// 明确选择使用 USB 已配对的同一台 Mac，经 TLS 握手后才保存网络入口。
    func connectUsingUSBPairing() {
        do {
            guard let key = try loadKey("usb:paired-host") else {
                linkStatus = "还没有已保存的 USB 配对，请输入 Mac 显示的配对码。"
                return
            }
            code = key
            connect()
        } catch { linkStatus = error.localizedDescription }
    }

    /// Wi-Fi 主动连接用户选定的 Mac；USB 仅在手机回环接口等待持有同一密钥的 Mac。
    func connect() {
        guard transport != .bluetooth else { return }
        guard link == nil, usbListener == nil else { return }
        if transport == .wifi, endpoint == nil {
            linkStatus = "请选择在线 Mac，或输入有效的主机地址与 1–65535 的端口。"
            return
        }
        let keyAccount = account
        do {
            let input = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            var key = input
            if key.isEmpty {
                key = try loadKey(keyAccount) ?? ""
                if key.isEmpty, transport == .wifi, selectedHost == Self.manual {
                    // 兼容旧版按地址保存的配对记录。握手成功后写入含端口的新记录。
                    key = try loadKey("address:" + address) ?? ""
                }
            }
            let parameters = try RemotePairing.parameters(key)
            if transport == .usb {
                try listenUSB(parameters, key: key, account: keyAccount)
            } else if let endpoint {
                let name = selectedHost == Self.manual ? address : selectedHost
                attach(NWConnection(to: endpoint, using: parameters), key: key, keyAccount: keyAccount, name: name)
            }
        } catch { linkStatus = error.localizedDescription }
    }

    /// 不发布 Bonjour，只接受 usbmuxd 转发到设备回环端口的流；同时最多处理一个连接。
    private func listenUSB(_ parameters: NWParameters, key: String, account: String) throws {
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: RemotePairing.usbPort)!)
        let listener = try NWListener(using: parameters)
        usbListener = listener
        usbListening = true
        linkStatus = "正在开启 USB 监听…"
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.usbListener === listener else { return }
                switch state {
                case .ready:
                    if self.link == nil { self.linkStatus = "手机 USB 已就绪。请在 Mac 的「设备」页点击「连接 USB 手机」。" }
                case .waiting(let error):
                    self.linkStatus = "USB 监听尚未就绪 · " + error.localizedDescription
                case .failed(let error):
                    self.disconnect()
                    self.linkStatus = "USB 监听失败 · " + error.localizedDescription
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor in
                guard let self, let listener, self.usbListener === listener, self.link == nil else {
                    connection.cancel()
                    return
                }
                self.attach(connection, key: key, keyAccount: account, name: "USB · 已配对的 Mac")
            }
        }
        listener.start(queue: queue)
    }

    /// 两条传输共用 TLS 鉴权、设备列表、命令收发和轮询。仅在成功查询主机后保存凭据。
    private func attach(_ connection: NWConnection, key: String, keyAccount: String, name: String) {
        let channel = RemoteLink(connection)
        link = channel
        let ownAccount = RemotePairing.bindingAccount(hostKey: key)
        bindingAccount = ownAccount
        linkStatus = "正在连接 " + name + " 并验证配对…"
        busy = true
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection, self.link?.connection === connection else { return }
                if case .failed(let error) = state {
                    self.disconnectLink()
                    self.linkStatus = "连接失败，请核对配对码与网络。\(error.localizedDescription)"
                } else if case .waiting(let error) = state {
                    self.linkStatus = "正在等待网络 · " + error.localizedDescription
                }
            }
        }
        connection.start(queue: queue)
        Task {
            var grant: DeviceGrant?
            if transport == .wifi {
                do {
                    if let saved = try loadKey(ownAccount) {
                        grant = try JSONDecoder().decode(DeviceGrant.self, from: Data(saved.utf8))
                    }
                } catch { bindingMessage = "无法读取本机绑定，请重新通过 USB 绑定。" }
            }
            guard await exchange(RemoteRequest(.status, grant: grant), over: channel), link?.connection === connection else { return }
            if transport == .wifi, selectedHost == Self.manual {
                preferences.set(manualHost, forKey: "mobile.mac.address")
                preferences.set(port, forKey: "mobile.mac.port")
            }
            connected = true
            linkStatus = "已连接 · " + name
            do { try saveKey(key, account: keyAccount); code = "" }
            catch { linkStatus += "（配对未保存）" }
            polling = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
                    guard link?.connection === connection else { return }
                    if !busy {
                        let task = Task { await exchange(RemoteRequest(.status), over: channel) }
                        refresh = task
                        _ = await task.value
                        if link?.connection === connection { refresh = nil }
                    }
                }
            }
        }
    }

    /// 断开仅影响手机。等待执行回执时失联会保留结果未知说明。
    func disconnect() {
        usbListener?.cancel()
        usbListener = nil
        usbListening = false
        disconnectLink()
    }

    /// USB 传输中断后继续监听同一密钥，显式断开或进入后台时由调用方关闭监听器。
    private func disconnectLink() {
        if pendingChange { receipt = "与 Mac 失联，设备结果未知。重连后核对目标，必要时清除。" }
        pendingChange = false
        polling?.cancel()
        polling = nil
        refresh?.cancel()
        refresh = nil
        link?.connection.cancel()
        link = nil
        requestInFlight = nil
        targets = []
        boundDevice = nil
        bindingAccount = nil
        bindingMessage = ""
        busy = false
        connected = false
        linkStatus = "未连接 Mac"
    }

    /// 手机删除选定 Mac 的本地配对记录并立即断开。
    func forget() {
        disconnect()
        resumeHost = nil
        resumeUSB = false
        code = ""
        do {
            if let key = try loadKey(account) {
                try saveKey(nil, account: RemotePairing.bindingAccount(hostKey: key))
            }
            try saveKey(nil, account: account)
            if transport == .wifi, selectedHost == Self.manual {
                try saveKey(nil, account: "address:" + address)
            }
            linkStatus = "已忘记此 Mac"
        }
        catch { linkStatus = error.localizedDescription }
    }

    /// 提交不可变草稿或清除请求；只允许明确选定且可用的目标。
    @discardableResult
    func submit(_ point: GeoPoint?, confirmedTarget: RemoteTarget? = nil) async -> Bool {
        guard boundDevice != nil else { return false }
        if let confirmedTarget, target?.id != confirmedTarget.id || target?.session != confirmedTarget.session {
            receipt = point == nil ? "目标会话已变化，请重新确认恢复。" : "目标会话已变化，请重新确认选点。"
            return false
        }
        guard connected, !busy, let channel = link, let target, target.available,
              point == nil || !target.needsClear else { return false }
        let request = RemoteRequest(point == nil ? .clear : .apply, target: target,
                                    latitude: point?.latitude, longitude: point?.longitude)
        busy = true
        if let refresh { _ = await refresh.value }
        guard link?.connection === channel.connection else { return false }
        pendingChange = true
        receipt = "正在向 Mac 发送…"
        return await exchange(request, over: channel)
    }

    /// 顺序处理送达和执行回执；超时取消本连接，不重试写入。只接受当前连接和请求的回执。
    private func exchange(_ request: RemoteRequest, over channel: RemoteLink) async -> Bool {
        guard request.action == .status || (connected && boundDevice != nil && request.device == boundDevice) else { return false }
        guard link?.connection === channel.connection, requestInFlight == nil else { return false }
        requestInFlight = request.id
        let controlsBusy = !connected || request.action != .status
        if controlsBusy { busy = true }
        let deadline = DispatchWorkItem { channel.connection.cancel() }
        queue.asyncAfter(deadline: .now() + (request.action == .status ? 12 : 150), execute: deadline)
        defer {
            deadline.cancel()
            if requestInFlight == request.id {
                requestInFlight = nil
                if controlsBusy { busy = false; pendingChange = false }
            }
        }
        do {
            try await channel.send(request)
            while true {
                let response = try await channel.receive(RemoteReply.self)
                guard link?.connection === channel.connection else { return false }
                guard response.id == request.id else { throw RemoteError("回执与本次请求不匹配。") }
                if response.phase == .delivered { receipt = response.message; continue }
                if transport == .usb, let grant = response.grant, response.boundDevice != nil, let bindingAccount {
                    do {
                        let data = try JSONEncoder().encode(grant)
                        try saveKey(String(decoding: data, as: UTF8.self), account: bindingAccount)
                    } catch { linkStatus = "本轮 USB 已绑定，Wi-Fi 凭据保存失败。" }
                }
                boundDevice = response.boundDevice
                targets = response.targets.filter { $0.id == response.boundDevice }
                if boundDevice == nil {
                    bindingMessage = "当前连接尚未验证本机。请使用新版 Mac 控制台，通过 USB 连接本机完成首次绑定。"
                } else {
                    bindingMessage = target?.available == true ? "已绑定本机" : "本机已绑定，请在 Mac 刷新对应链路的真机列表。"
                }
                if request.action != .status {
                    receipt = (request.device ?? "") + " · " + response.message
                } else if response.phase != .status { throw RemoteError(response.message) }
                return response.phase == .status || response.phase == .accepted
            }
        } catch {
            if link?.connection === channel.connection {
                let previous = linkStatus
                disconnectLink()
                if usbListening {
                    linkStatus = "USB 握手中断 · " + error.localizedDescription + "。请核对 Mac 配对码；如需重输，先断开接收。"
                    return false
                }
                linkStatus = "连接中断（" + error.localizedDescription + "）。" + (previous.hasPrefix("正在") ? "请核对局域网、所选主机与配对码。" : "请重新连接。")
            }
            return false
        }
    }
}
