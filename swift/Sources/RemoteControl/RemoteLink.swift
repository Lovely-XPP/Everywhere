import CryptoKit
import Foundation
import Network
import Security

/// 同一主机共享一个高熵配对密钥。服务名称仅用于发现；TLS 握手验证双方持有同一密钥。
public enum RemotePairing {
    /// 手机仅在本机回环接口监听此 TCP 端口，Mac 通过 USB 转发到达。
    public static let usbPort: UInt16 = 49371
    /// 网络遥控的默认 TCP 监听端口，可在 Mac 面板中更换。
    public static let networkPort: UInt16 = 49372

    /// 解析手动输入的十进制端口；0 仅用于系统分配，不能作为公开地址。
    public static func parsePort(_ text: String) -> UInt16? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = UInt16(raw), value > 0 else { return nil }
        return value
    }

    public static let service = "_vloc-remote._tcp"

    /// 生成 128 位随机密钥，使用 32 个十六进制字符以便跨设备输入。
    public static func generate() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RemoteError("系统无法生成配对码。")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// 仅接受固定长度随机码。TLS 1.2 仅启用具备认证加密的 PSK 套件。
    public static func parameters(_ code: String) throws -> NWParameters {
        guard code.utf8.count == 32, code.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RemoteError("请输入 Mac 显示的 32 位配对码。")
        }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!)
        let key = Array(code.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Array("VirtualLocation/1".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, key as __DispatchData, identity as __DispatchData)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.preferNoProxies = true
        return parameters
    }

    /// 使用主机配对密钥的摘要区分不同 Mac，撤销主机配对时旧绑定自动失效。
    public static func bindingAccount(hostKey: String) -> String {
        "self-binding:" + SHA256.hash(data: Data(hostKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 读取本机钥匙串；无记录时返回 nil，访问被拒绝时抛错。
    public static func load(_ account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let code = String(data: data, encoding: .utf8) else {
            throw RemoteError("无法读取钥匙串（\(status)）。")
        }
        return code
    }

    /// 将已确认的配对码保存在本机钥匙串；nil 删除记录。系统错误时保留诊断。
    public static func save(_ code: String?, account: String) throws {
        let query = query(account)
        let status: OSStatus
        if let code {
            let attributes: [CFString: Any] = [kSecValueData: Data(code.utf8), kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
            let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            status = update == errSecItemNotFound
                ? SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) : update
        } else {
            status = SecItemDelete(query as CFDictionary)
            if status == errSecItemNotFound { return }
        }
        guard status == errSecSuccess else { throw RemoteError("无法更新钥匙串（\(status)）。") }
    }

    private static func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.virtuallocation.remote.v1", kSecAttrAccount: account]
    }
}

/// TLS 流中顺序传输有长度上限的 JSON 帧；调用方为每条连接维持唯一读取循环。
public struct RemoteLink: Sendable {
    public let connection: NWConnection
    public init(_ connection: NWConnection) { self.connection = connection }

    /// 在 Network 队列异步发送完整消息；断线或取消连接会结束等待。
    public func send<T: Encodable>(_ message: T) async throws {
        let body = try JSONEncoder().encode(message)
        guard body.count <= 256 * 1024 else { throw RemoteError("消息超过大小限制。") }
        var count = UInt32(body.count).bigEndian
        var frame = withUnsafeBytes(of: &count) { Data($0) }
        frame.append(body)
        try await sendBytes(frame)
    }

    /// 发送已编码的协议字节；系统错误或连接取消时抛错。
    public func sendBytes(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    /// 接收下一帧；长度非法、半帧断线或解码失败均终止本连接。
    public func receive<T: Decodable>(_ type: T.Type) async throws -> T {
        let header = try await read(4)
        let count = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...256 * 1024).contains(count) else { throw RemoteError("消息长度无效。") }
        return try JSONDecoder().decode(type, from: await read(count))
    }

    /// 精确读取 count 个字节；调用方负责校验长度，半帧断线时抛错。
    public func read(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: RemoteError("与对端的连接已关闭。")) }
            }
        }
    }
}
