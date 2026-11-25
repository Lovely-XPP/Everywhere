import Combine
import Foundation
import Network
import RemoteControl

/// 缓存仍在有效期内的请求及执行任务。重传可等待原回执，不会再次操作设备。
@MainActor
final class RemoteLedger {
    private var entries: [UUID: (RemoteRequest, Task<RemoteReply, Never>)] = [:]

    /// USB 只允许控制连线的这台设备，跨设备请求在读取去重缓存前拒绝；Wi-Fi 沿用主机目标列表。
    func perform(_ request: RemoteRequest, model: MacConsoleModel, boundTo device: String? = nil) async -> RemoteReply {
        if let device, request.action != .status, request.device != device {
            return RemoteReply(request, .rejected, "此连接仅允许操作已绑定的本机。")
        }
        let reply = await execute(request, model: model)
        guard let device else { return reply }
        return RemoteReply(request, reply.phase, reply.message, targets: reply.targets.filter { $0.id == device })
    }

    private func execute(_ request: RemoteRequest, model: MacConsoleModel) async -> RemoteReply {
        if request.action == .status { return await model.handleRemote(request) }
        entries = entries.filter { $0.value.0.expires.timeIntervalSinceNow >= 0 }
        if let (previous, task) = entries[request.id] {
            guard previous == request else { return RemoteReply(request, .rejected, "请求 ID 对应的参数不一致。") }
            return await task.value
        }
        guard (0...60).contains(request.expires.timeIntervalSinceNow), entries.count < 2048 else {
            return RemoteReply(request, .rejected, "请求超出有效期或 Mac 请求过多。")
        }
        let task = Task { await model.handleRemote(request) }
        entries[request.id] = (request, task)
        return await task.value
    }
}

/// 在主 actor 之外串行访问钥匙串，等待系统授权时地图和设备操作仍可响应。
actor HostPairingIdentity {
    private let account = "mac-host"
    private let load: (String) throws -> String?
    private let save: (String?, String) throws -> Void

    init(load: @escaping (String) throws -> String? = RemotePairing.load,
         save: @escaping (String?, String) throws -> Void = RemotePairing.save) {
        self.load = load
        self.save = save
    }

    func code() throws -> String {
        if let existing = try load(account) { return existing }
        let secret = try RemotePairing.generate()
        try save(secret, account)
        return secret
    }

    /// 只有 usbmuxd 确认的设备能领取对应令牌，网络端只允许核验已有令牌。
    func grant(forUSB device: String, hostKey: String) throws -> DeviceGrant {
        let account = RemotePairing.bindingAccount(hostKey: hostKey) + ":" + device.replacingOccurrences(of: "-", with: "").lowercased()
        if let token = try load(account) { return DeviceGrant(device: device, token: token) }
        let token = try RemotePairing.generate()
        try save(token, account)
        return DeviceGrant(device: device, token: token)
    }

    func verify(_ grant: DeviceGrant, hostKey: String) throws -> String? {
        guard !grant.device.isEmpty, grant.device.utf8.count <= 64, grant.token.utf8.count == 32,
              let expected = try load(RemotePairing.bindingAccount(hostKey: hostKey) + ":" + grant.device.replacingOccurrences(of: "-", with: "").lowercased()),
              expected == grant.token else { return nil }
        return grant.device
    }

    func revoke() throws { try save(nil, account) }
}

/// 仅在人工开启时发布 Bonjour 服务。撤销配对会关闭所有控制连接，设备会话继续由 Mac 持有。
@MainActor
final class RemoteHost: ObservableObject {
    @Published private(set) var code = ""
    @Published private(set) var message = "未开启"
    @Published private(set) var enabled = false
    @Published private(set) var usbDevice: String?
    @Published private(set) var usbMessage = "USB 未开启"
    private var usbTask: Task<Void, Never>?
    private var usbToken: UUID?
    private var listener: NWListener?
    private var peers: [UUID: NWConnection] = [:]
    private let queue = DispatchQueue(label: "VirtualLocation.remote.host")
    private let ledger = RemoteLedger()
    private let identity: HostPairingIdentity
    init(identity: HostPairingIdentity = HostPairingIdentity()) { self.identity = identity }
    @Published private(set) var accessingKeychain = false

    /// 从本机钥匙串加载或生成配对码；网络和钥匙串失败会回到可重试状态。
    func start(_ model: MacConsoleModel, port: String = String(RemotePairing.networkPort), advertise: Bool = true) async {
        guard !enabled, !accessingKeychain else { return }
        guard let value = RemotePairing.parsePort(port), let endpointPort = NWEndpoint.Port(rawValue: value) else {
            message = "TCP 端口必须介于 1 和 65535 之间。"
            return
        }
        accessingKeychain = true
        message = "正在读取配对凭据…"
        defer { accessingKeychain = false }
        do {
            let secret = try await identity.code()
            try listen(model, secret: secret, port: endpointPort, advertise: advertise)
        } catch { message = error.localizedDescription }
    }

    /// 监听指定 TCP 端口；同一入口供手动地址和 Bonjour 使用，连接必须通过配对握手。
    func listen(_ model: MacConsoleModel, secret: String, port: NWEndpoint.Port, advertise: Bool) throws {
        let server = try NWListener(using: RemotePairing.parameters(secret), on: port)
        if advertise {
            server.service = .init(name: ProcessInfo.processInfo.hostName, type: RemotePairing.service)
        }
        server.stateUpdateHandler = { [weak self, weak server] state in
            Task { @MainActor in
                guard let self, let server, self.listener === server else { return }
                switch state {
                case .ready: self.message = "正在监听 TCP \(server.port ?? port) · TLS 配对认证"
                case .failed(let error): self.stopWiFi(); self.message = "TCP \(port) 启动失败 · " + error.localizedDescription
                case .waiting(let error): self.message = "等待网络 · " + error.localizedDescription
                default: break
                }
            }
        }
        server.newConnectionHandler = { [weak self, weak model, weak server] connection in
            Task { @MainActor in
                guard let self, let model, let server, self.listener === server,
                      self.peers.count < 16 else { connection.cancel(); return }
                let token = UUID()
                self.peers[token] = connection
                connection.start(queue: self.queue)
                _ = await self.serve(RemoteLink(connection), token: token, model: model, hostKey: secret)
            }
        }
        listener = server
        code = secret
        enabled = true
        message = "正在启动…"
        server.start(queue: queue)
    }

    /// 锁定人工选定的真机。切后台、握手超时或拔线后仅重连同一 UDID，从不重放写操作。
    func startUSB(_ model: MacConsoleModel) async {
        guard !accessingKeychain, usbTask == nil, model.backendMode.supportsUSBController else { return }
        accessingKeychain = true
        let selected = model.selectedDeviceID
        usbMessage = "正在查询数据线上的设备…"
        defer { accessingKeychain = false }
        do {
            let list = try await USBRemoteConnection.deviceList()
            let id: String
            if let selected {
                _ = try MuxPacket.usbNumber(in: list, for: selected)
                id = selected
            } else {
                let wired = try MuxPacket.wiredDevices(in: list)
                guard wired.count == 1 else {
                    usbMessage = wired.isEmpty ? "未检测到 USB 设备。请用数据线连接 iPhone 并解锁。" : "有多台 USB 设备，请在目标设备中选择一台，或只保留要连接的手机。"
                    return
                }
                id = wired[0].serial
            }
            usbMessage = "正在读取配对凭据…"
            let key = try await identity.code()
            guard model.selectedDeviceID == selected, model.backendMode.supportsUSBController else {
                usbMessage = "目标已变化，请重新开启 USB 连接。"
                return
            }
            code = key
            usbDevice = id
            usbMessage = "正在连接手机。请在手机输入此 Mac 的配对码并开启 USB 接收。"
            usbTask = Task { [weak self] in
                guard let self else { return }
                var previousNumber: UInt32?
                while !Task.isCancelled, model.backendMode.supportsUSBController {
                    do {
                        let (connection, number) = try await USBRemoteConnection.connection(device: id, code: key)
                        try Task.checkCancellation()
                        if let previousNumber, previousNumber != number { await model.usbCableLost(id) }
                        previousNumber = number
                        try Task.checkCancellation()
                        let token = UUID()
                        usbToken = token
                        peers[token] = connection
                        let handshakeTimeout = DispatchWorkItem { [weak connection] in connection?.cancel() }
                        queue.asyncAfter(deadline: .now() + 8, execute: handshakeTimeout)
                        connection.stateUpdateHandler = { [weak self, weak connection] state in
                            switch state {
                            case .ready:
                                handshakeTimeout.cancel()
                                Task { @MainActor in
                                    guard let self, self.usbToken == token else { return }
                                    self.usbMessage = "USB 通道已建立，正在核对本机绑定…"
                                }
                            case .waiting, .failed: connection?.cancel()
                            default: break
                            }
                        }
                        connection.start(queue: queue)
                        let failure = await serve(RemoteLink(connection), token: token, model: model, hostKey: key, boundTo: id)
                        handshakeTimeout.cancel()
                        guard !Task.isCancelled else { return }
                        usbToken = nil
                        usbMessage = "等待 USB 重连 · " + (failure ?? "手机已断开")
                    } catch {
                        guard !Task.isCancelled else { return }
                        usbMessage = error.localizedDescription
                        if error is MuxPacket.MissingCable { await model.usbCableLost(id) }
                    }
                    do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                }
                if !Task.isCancelled { stopUSB() }
            }
        } catch { usbMessage = error.localizedDescription }
    }

    /// 只关闭 USB 遥控，不向设备发送清除操作。
    func stopUSB() {
        usbTask?.cancel()
        usbTask = nil
        if let usbToken { peers.removeValue(forKey: usbToken)?.cancel() }
        usbToken = nil
        usbDevice = nil
        usbMessage = "USB 未开启"
        if !enabled { code = "" }
    }

    /// 每个连接顺序读取有限长度的消息。读取超时仅结束网络连接，不会撤销执行中的 USB 操作。
    private func serve(_ link: RemoteLink, token: UUID, model: MacConsoleModel, hostKey: String, boundTo device: String? = nil) async -> String? {
        defer { peers.removeValue(forKey: token); link.connection.cancel() }
        var verifiedDevice = device
        var first = true
        do {
            while peers[token] != nil {
                let deadline = DispatchWorkItem { link.connection.cancel() }
                queue.asyncAfter(deadline: .now() + 45, execute: deadline)
                let request: RemoteRequest
                do { defer { deadline.cancel() }; request = try await link.receive(RemoteRequest.self) }
                guard peers[token] != nil else { return nil }
                var issued: DeviceGrant?
                if first {
                    guard request.action == .status else { throw RemoteError("请先验证本机绑定。") }
                    if let device {
                        issued = try await identity.grant(forUSB: device, hostKey: hostKey)
                        if [.automatic, .wired].contains(model.backendMode), model.devices[device]?.isAvailable != true {
                            Task { await model.refreshDevices() }
                        }
                    }
                    else if let grant = request.grant { verifiedDevice = try await identity.verify(grant, hostKey: hostKey) }
                    first = false
                }
                guard peers[token] != nil else { return nil }
                guard let verifiedDevice else {
                    try await link.send(RemoteReply(request, request.action == .status ? .status : .rejected,
                        "已连接 Mac。请先通过 USB 连接一次本机以绑定身份。"))
                    continue
                }
                if request.action != .status {
                    try await link.send(RemoteReply(request, .delivered, "Mac 已收到命令。"))
                }
                guard peers[token] != nil else { return nil }
                if let device, request.action == .status {
                    model.confirmUSBController(device)
                    if usbToken == token { usbMessage = "USB 已连接 · 已验证本机" }
                }
                // 同一真机在 USB 工具和 CoreDevice 中的 UDID 大小写或连字符可能不同。
                let normalized = verifiedDevice.replacingOccurrences(of: "-", with: "").lowercased()
                let candidates = model.deviceIDs.filter { $0.replacingOccurrences(of: "-", with: "").lowercased() == normalized }
                guard model.backendMode.supportsUSBController, candidates.count <= 1 else {
                    try await link.send(RemoteReply(request, request.action == .status ? .status : .rejected,
                        "请在 Mac 上准备本机的真机定位后端。", boundDevice: verifiedDevice, grant: issued))
                    continue
                }
                let resolvedID = candidates.first ?? verifiedDevice
                let reply = await ledger.perform(request, model: model, boundTo: resolvedID)
                try await link.send(RemoteReply(request, reply.phase, reply.message, targets: reply.targets,
                                                boundDevice: resolvedID, grant: issued))
            }
        } catch { return error.localizedDescription }
        return nil
    }

    /// 停止发布和接收指令，保留钥匙串配对及正在运行的设备会话。
    func stopWiFi() {
        listener?.cancel()
        listener = nil
        for id in Array(peers.keys) where id != usbToken { peers.removeValue(forKey: id)?.cancel() }
        enabled = false
        if usbDevice == nil { code = "" }
        message = "未开启"
    }

    /// 撤销所有使用当前配对码的手机，下次开启时生成新码。
    func revoke() async {
        guard !accessingKeychain else { return }
        accessingKeychain = true
        defer { accessingKeychain = false }
        stopWiFi()
        stopUSB()
        do { try await identity.revoke(); message = "已撤销所有手机配对。" }
        catch { message = error.localizedDescription }
    }
}
