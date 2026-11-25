import Foundation
import Network
import RemoteControl

/// Mac 只向本机系统 usbmuxd 查询有线设备；每次重连按 UDID 重新解析短期连接编号。
enum USBRemoteConnection {
    private static let daemon = NWEndpoint.unix(path: "/var/run/usbmuxd")
    private static let queue = DispatchQueue(label: "VirtualLocation.usbmux.discovery")

    /// 返回经 usbmuxd Connect 握手后才启动 TLS 的连接；调用方负责启动、超时和取消。
    /// - Parameters:
    ///   - device: 已在 Mac 控制台确认的真机 UDID。
    ///   - code: 与手机带外核对的主机配对码。
    ///   - endpoint: 系统守护进程的 UNIX 地址，测试可以注入本机替身。
    /// - Throws: 查询超时、查询回执无效、USB 目标缺失或凭据无效。
    static func connection(device: String, code: String, endpoint: NWEndpoint = daemon) async throws -> (NWConnection, UInt32) {
        let payload = try await deviceList(endpoint: endpoint)
        let number = try MuxPacket.usbNumber(in: payload, for: device)
        let options = NWProtocolFramer.Options(definition: USBConnectHandshake.definition)
        options["device"] = number
        let parameters = try RemotePairing.parameters(code)
        // 协议从应用层至传输层排列：上层 TLS 只能在底层 Connect 成功之后发送握手字节。
        parameters.defaultProtocolStack.applicationProtocols.append(options)
        return (NWConnection(to: endpoint, using: parameters), number)
    }
    /// 读取系统的 USB 和网络设备记录，不打开手机端口，不依赖定位后端。
    static func deviceList(endpoint: NWEndpoint = daemon) async throws -> Data {
        let query = NWConnection(to: endpoint, using: .tcp)
        let timeout = DispatchWorkItem { query.cancel() }
        queue.asyncAfter(deadline: .now() + 5, execute: timeout)
        defer { timeout.cancel(); query.cancel() }
        return try await withTaskCancellationHandler {
            query.start(queue: queue)
            let link = RemoteLink(query)
            try await link.sendBytes(MuxPacket.encode(["MessageType": "ListDevices"]))
            let size = try MuxPacket.payloadSize(try await link.read(16))
            return try await link.read(size)
        } onCancel: { query.cancel() }
    }

}

/// usbmux plist v1 的 16 字节小端头。每次查询使用独立 socket 和固定请求标签 1。
enum MuxPacket {
    static func encode(_ fields: [String: Any]) throws -> Data {
        var plist = fields
        plist["ProgName"] = "VirtualLocationHost"
        plist["ClientVersionString"] = "VirtualLocationHost/1"
        plist["kLibUSBMuxVersion"] = 3
        let payload = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        var data = Data()
        for word: UInt32 in [UInt32(16 + payload.count), 1, 8, 1] {
            var little = word.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(payload)
        return data
    }

    /// 按 usbmux plist v1 在端口字段中写入大端 TCP 端口号，设备编号为当次枚举结果。
    static func connectRequest(to device: UInt32) throws -> Data {
        try encode(["MessageType": "Connect", "DeviceID": device, "PortNumber": RemotePairing.usbPort.bigEndian])
    }

    /// Connect 必须收到 Result 成功回执后才可在同一条流上握手 TLS。
    static func didConnect(_ body: Data) throws -> Bool {
        let result = try PropertyListSerialization.propertyList(from: body, options: [], format: nil) as? [String: Any]
        return result?["MessageType"] as? String == "Result" && result?["Number"] as? Int == 0
    }

    /// 校验回执协议、标签与长度上限，返回 plist 字节数。
    static func payloadSize(_ header: Data) throws -> Int {
        guard header.count == 16 else { throw RemoteError("usbmuxd 回执头不完整。") }
        let words = header.withUnsafeBytes { buffer in
            stride(from: 0, to: 16, by: 4).map { UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: $0, as: UInt32.self)) }
        }
        guard words[1...] == [1, 8, 1], (17...1_048_576).contains(words[0]) else {
            throw RemoteError("usbmuxd 回执头无效。")
        }
        return Int(words[0]) - 16
    }

    /// 系统返回的 USB 设备编号与序列号；同机的网络记录不参与电缆选择。
    static func wiredDevices(in data: Data) throws -> [(serial: String, number: UInt32)] {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let list = (plist as? [String: Any])?["DeviceList"] as? [[String: Any]] else {
            throw RemoteError("usbmuxd 没有返回设备列表。")
        }
        return list.compactMap { entry in
            guard let properties = entry["Properties"] as? [String: Any],
                  properties["ConnectionType"] as? String == "USB",
                  let serial = properties["SerialNumber"] as? String, !serial.isEmpty,
                  let id = entry["DeviceID"] as? UInt32, id != 0 else { return nil }
            return (serial, id)
        }
    }

    /// 只接受唯一、序列号相符的 USB 设备。
    static func usbNumber(in data: Data, for device: String) throws -> UInt32 {
        func normalized(_ value: String) -> String { value.replacingOccurrences(of: "-", with: "").lowercased() }
        let matches = try wiredDevices(in: data).filter { normalized($0.serial) == normalized(device) }
        guard matches.count == 1 else { throw MissingCable() }
        return matches[0].number
    }

    /// 仅成功读取设备列表且无法唯一匹配时报告物理目标缺失。
    struct MissingCable: LocalizedError {
        var errorDescription: String? { "未找到唯一匹配的 USB 真机，请核对数据线和所选设备。" }
    }
}

/// 在 UNIX 流上先完成 usbmuxd 端口连接。握手完成后原样传送上层 TLS 字节。
private final class USBConnectHandshake: NWProtocolFramerImplementation {
    static let label = "VirtualLocation USB Connect"
    static let definition = NWProtocolFramer.Definition(implementation: USBConnectHandshake.self)
    private var bodyLength: Int?
    required init(framer: NWProtocolFramer.Instance) {}

    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        do {
            guard let id = framer.options["device"] as? UInt32 else { throw RemoteError("缺少设备编号。") }
            framer.writeOutput(data: try MuxPacket.connectRequest(to: id))
        } catch { framer.markFailed(error: .posix(.EINVAL)) }
        return .willMarkReady
    }

    /// 处理分片回执，精确消费 plist 字节，保留后续 TLS 握手数据。
    func handleInput(framer: NWProtocolFramer.Instance) -> Int {
        func take(_ count: Int) -> Data? {
            var data: Data?
            _ = framer.parseInput(minimumIncompleteLength: count, maximumLength: count) { buffer, _ in
                guard let buffer, buffer.count == count else { return 0 }
                data = Data(buffer)
                return count
            }
            return data
        }
        do {
            if bodyLength == nil {
                guard let header = take(16) else { return 16 }
                bodyLength = try MuxPacket.payloadSize(header)
            }
            guard let size = bodyLength, let body = take(size) else { return bodyLength ?? 16 }
            guard try MuxPacket.didConnect(body) else {
                framer.markFailed(error: .posix(.ECONNREFUSED))
                return 0
            }
            framer.passThroughInput()
            framer.passThroughOutput()
            framer.markReady()
        } catch { framer.markFailed(error: .posix(.EPROTO)) }
        return 0
    }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message,
                      messageLength: Int, isComplete: Bool) {
        do { try framer.writeOutputNoCopy(length: messageLength) }
        catch { framer.markFailed(error: .posix(.EIO)) }
    }
    func wakeup(framer: NWProtocolFramer.Instance) {}
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
}
