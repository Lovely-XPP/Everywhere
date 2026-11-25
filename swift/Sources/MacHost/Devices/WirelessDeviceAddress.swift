import Foundation
import Network
import RemoteControl

/// 通过指定 IP 上的设备服务读取标识。仅查询单个用户输入的地址，不建立配对。
enum WirelessDeviceAddress {
    /// 将数字地址规范为可比较的网络字节；域名和附带端口的输入均无效。
    static func bytes(_ address: String) -> Data? {
        IPv4Address(address)?.rawValue ?? IPv6Address(address)?.rawValue
    }

    /// 系统 usbmuxd 的 NetworkAddress 为 Darwin sockaddr，端口采用网络字节序。
    static func networkIDs(in data: Data, address: Data) throws -> Set<String> {
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let list = (plist as? [String: Any])?["DeviceList"] as? [[String: Any]] else { throw RemoteError("无效的系统设备列表。") }
        return Set(list.compactMap { entry in
            guard let props = entry["Properties"] as? [String: Any], props["ConnectionType"] as? String == "Network",
                  let socket = props["NetworkAddress"] as? Data, socket.count >= 2,
                  let id = props["SerialNumber"] as? String, !id.isEmpty else { return nil }
            let range: Range<Int>
            switch Int32(socket[1]) {
            case AF_INET: range = 4..<8
            case AF_INET6: range = 8..<24
            default: return nil
            }
            guard socket.count >= range.upperBound, socket.subdata(in: range) == address else { return nil }
            return id
        })
    }

    /// 无系统网络记录时，从指定 IP 的 lockdownd 只读查询 UniqueDeviceID，最多等待五秒。
    /// 该回答只用于与 Xcode 的已配对无线设备比对。
    static func deviceID(at address: String) async throws -> String {
        guard let ip = bytes(address) else { throw RemoteError("请输入 iPhone 的 IPv4 或 IPv6 地址。") }
        if let list = try? await USBRemoteConnection.deviceList() {
            let matches = try networkIDs(in: list, address: ip)
            if matches.count > 1 { throw RemoteError("该 IP 对应多个系统设备记录，无法确认目标。") }
            if let id = matches.first { return id }
        }
        try Task.checkCancellation()
        let queue = DispatchQueue(label: "Everywhere.wifi.identity")
        let connection = NWConnection(host: NWEndpoint.Host(address), port: 62078, using: .tcp)
        let deadline = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + 5, execute: deadline)
        defer { deadline.cancel(); connection.cancel() }
        return try await withTaskCancellationHandler {
            connection.start(queue: queue)
            let link = RemoteLink(connection)
            let fields = ["Label": "Everywhere", "Request": "GetValue", "Key": "UniqueDeviceID"]
            let body = try PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0)
            var length = UInt32(body.count).bigEndian
            var frame = withUnsafeBytes(of: &length) { Data($0) }
            frame.append(body)
            try await link.sendBytes(frame)
            let size = try await link.read(4).reduce(0) { $0 << 8 | Int($1) }
            guard (1...65536).contains(size) else { throw RemoteError("设备身份回执长度无效。") }
            let payload = try await link.read(size)
            let reply = try PropertyListSerialization.propertyList(from: payload, options: [], format: nil)
            guard let id = (reply as? [String: Any])?["Value"] as? String, !id.isEmpty else {
                throw RemoteError("该地址未返回设备标识，请先在 Xcode 确认无线配对。")
            }
            return id
        } onCancel: { connection.cancel() }
    }
}
