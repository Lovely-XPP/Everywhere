import CryptoKit
import Foundation
import Security

/// 本机 MFi v3 身份。证书保留完整 PKCS#7 容器，与配套私钥一起原子写入钥匙串。
private struct Identity: Codable {
    let certificate: Data
    let privateKey: Data

    /// 按字节上限读取常规文件。文件缺失、不可读或过大时终止当前请求。
    private static func read(_ url: URL, limit: Int) throws -> Data {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              let file = try? FileHandle(forReadingFrom: url) else {
            throw Failure("无法读取配件身份文件，请检查路径和访问权限。")
        }
        defer { try? file.close() }
        guard let bytes = try file.read(upToCount: limit + 1), !bytes.isEmpty, bytes.count <= limit else {
            throw Failure("身份文件为空或超出大小限制。")
        }
        return bytes
    }

    /// 保留原有的命令行钥匙串配置入口。
    init(directory: URL) throws {
        try self.init(certificate: Self.read(directory.appendingPathComponent("certificate.p7b"), limit: 60 * 1024),
                      keyURL: directory.appendingPathComponent("identity.pk8"))
    }

    /// 按绝对路径读取私钥，并和本次会话发送的证书核对。
    init(certificate: Data, keyURL: URL) throws {
        try self.init(certificate: certificate, der: Self.read(keyURL, limit: 8192))
    }

    /// 校验已解封的 DER 身份并准备会话签名。
    init(certificate: Data, der: Data) throws {
        self.certificate = certificate
        guard let key = try? P256.Signing.PrivateKey(derRepresentation: der) else {
            throw Failure("无法读取 DER 格式的 P-256 私钥。")
        }
        var format = SecExternalFormat.formatPKCS7
        var kind = SecExternalItemType.itemTypeAggregate
        var items: CFArray?
        let status = SecItemImport(certificate as CFData, nil, &format, &kind, [], nil, nil, &items)
        guard status == errSecSuccess, let certificates = items as? [SecCertificate], !certificates.isEmpty else {
            throw Failure("无法读取 PKCS#7 证书包。")
        }
        let matches = certificates.contains { cert in
            guard let publicKey = SecCertificateCopyKey(cert),
                  let bytes = SecKeyCopyExternalRepresentation(publicKey, nil) else { return false }
            return bytes as Data == key.publicKey.x963Representation
        }
        guard matches else { throw Failure("证书与所选私钥不匹配。") }
        privateKey = key.x963Representation
    }

    /// iPhone 提供 32 字节摘要。返回按固定宽度拼接的 r、s，各 32 字节。
    func signature(for challenge: Data) throws -> Data {
        guard challenge.count == 32 else { throw Failure("需要 32 字节的 MFi v3 挑战。") }
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ]
        guard let key = SecKeyCreateWithData(privateKey as CFData, attributes as CFDictionary, nil),
              let der = SecKeyCreateSignature(key, .ecdsaSignatureDigestX962SHA256, challenge as CFData, nil)
        else { throw Failure("无法完成配件挑战签名。") }
        return try P256.Signing.ECDSASignature(derRepresentation: der as Data).rawRepresentation
    }

    /// 使用当前用户的本机登录钥匙串，由同一可执行文件负责写入及读取。
    static var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: "com.virtuallocation.iap2.mfi-v3",
         kSecAttrAccount: "accessory-identity"]
    }

    /// 新增或替换同一个钥匙串条目，写入失败时报告系统状态码。
    func store() throws {
        let data = try PropertyListEncoder().encode(self)
        // 登录钥匙串使用自己的锁定状态与访问控制；此条目不参与同步。
        let attributes: [CFString: Any] = [kSecValueData: data]
        let item = Self.query.merging(attributes) { _, new in new }
        let added = SecItemAdd(item as CFDictionary, nil)
        let status = added == errSecDuplicateItem
            ? SecItemUpdate(Self.query as CFDictionary, attributes as CFDictionary) : added
        guard status == errSecSuccess else { throw Failure("写入钥匙串失败（\(status)）。") }
    }

    /// 读取当前用户已导入的身份；区分从未导入和系统拒绝读取。
    static func load() throws -> Identity {
        var request = query
        request[kSecReturnData] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { throw Failure("本机缺少配件签名私钥。") }
        guard status == errSecSuccess, let data = result as? Data else {
            throw Failure("读取钥匙串失败（\(status)）。")
        }
        return try PropertyListDecoder().decode(Self.self, from: data)
    }
}

/// 只向调用方回传可展示的错误说明。
private struct Failure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// 从实际助手位置定位外层 App，兼容从最新导出目录的符号链接启动。
private var appURL: URL {
    let helper = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    return helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

private var certificateURL: URL {
    appURL.appendingPathComponent("Contents/Resources/asset/mfi/certificate.p7b")
}

/// 返回本次握手使用的 PKCS#7 数据；包内资源缺失或为空时报告错误。
private func bundledCertificate() throws -> Data {
    guard let certificate = try? Data(contentsOf: certificateURL), !certificate.isEmpty else {
        throw Failure("无法读取内置配件证书。")
    }
    return certificate
}

/// 读取本次会话签名身份，保留手动配置；新 Mac 默认从签名 App 自身读取。
private func signingIdentity(certificate: Data) throws -> Identity {
    if let path = UserDefaults.standard.persistentDomain(forName: "com.virtuallocation.machost")?["iap2.privateKeyPath"] as? String {
        guard path.hasPrefix("/") else { throw Failure("私钥路径必须是绝对路径。") }
        return try Identity(certificate: certificate, keyURL: URL(fileURLWithPath: path))
    }

    let files = FileManager.default
    let bundledKey = certificateURL.deletingLastPathComponent().appendingPathComponent("identity.pk8")
    let userKey = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Everywhere/MFi/identity.pk8")
    if let keyURL = [bundledKey, userKey].first(where: { files.isReadableFile(atPath: $0.path) }) {
        return try Identity(certificate: certificate, keyURL: keyURL)
    }
    return try Identity.load()
}

/// 与客户端通过逐行 JSON 通信。一次会话固定使用一套身份，导入入口单独运行。
private func serve() throws {
    let certificate = try bundledCertificate()
    var identity: Identity?
    while let line = readLine() {
        let response: [String: String]
        do {
            let request = try JSONDecoder().decode([String: String].self, from: Data(line.utf8))
            switch request["op"] {
            case "certificate":
                response = ["type": "mfi", "certificate": certificate.base64EncodedString()]
            case "sign":
                guard let encoded = request["challenge"], let challenge = Data(base64Encoded: encoded) else {
                    throw Failure("无法读取配件挑战。")
                }
                if identity == nil {
                    identity = try signingIdentity(certificate: certificate)
                }
                guard let current = identity, current.certificate == certificate else {
                    throw Failure("本机签名身份与内置证书不匹配。")
                }
                response = ["signature": try current.signature(for: challenge).base64EncodedString()]
            default:
                throw Failure("未知的配件认证请求。")
            }
        } catch {
            response = ["error": (error as? Failure)?.message ?? "无法处理配件认证请求。"]
        }
        var bytes = try JSONEncoder().encode(response)
        bytes.append(10)
        try FileHandle.standardOutput.write(contentsOf: bytes)
    }
}

do {
    switch Array(CommandLine.arguments.dropFirst()) {
    case let args where args.count == 4 && args[0] == "seal":
        let directory = URL(fileURLWithPath: args[1], isDirectory: true)
        let der = try Data(contentsOf: directory.appendingPathComponent("identity.pk8"))
        let certificate = try Data(contentsOf: directory.appendingPathComponent("certificate.p7b"))
        _ = try Identity(certificate: certificate, der: der)
        let unlock = try Data(contentsOf: URL(fileURLWithPath: args[2]))
        guard unlock.count == 32 else { throw Failure("本机解锁文件无效。") }
        let sealed = try AES.GCM.seal(der, using: SymmetricKey(data: unlock), authenticating: certificate)
        guard let bytes = sealed.combined else { throw Failure("无法封装私钥。") }
        try bytes.write(to: URL(fileURLWithPath: args[3]))
    case let args where args.count == 2 && args[0] == "import":
        let identity = try Identity(directory: URL(fileURLWithPath: args[1], isDirectory: true))
        guard identity.certificate == (try bundledCertificate()) else {
            throw Failure("所选目录的证书与 App 内置证书不匹配。")
        }
        try identity.store()
    case ["verify-bundle"]:
        _ = try Identity(directory: certificateURL.deletingLastPathComponent())
    case []:
        try serve()
    default:
        throw Failure("认证程序参数无效。")
    }
} catch {
    let message = (error as? Failure)?.message ?? "配件身份文件操作失败（\((error as NSError).domain) \((error as NSError).code)）。"
    FileHandle.standardError.write(Data(message.utf8))
    exit(1)
}
