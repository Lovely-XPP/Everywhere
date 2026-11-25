import Foundation

/// Mac 通过独立只读 BLE 服务公布所选设备的会话状态，不包含地址、坐标或认证材料。
public struct IAP2ConnectionReport: Codable, Equatable, Sendable {
    public static let serviceID = "8CC42C82-AC28-4F92-A5CF-4E76267234F4"
    public static let fieldID = "18A6B6AA-4113-477E-8C1C-4BB5C977AA26"
    public let target: String
    public let authenticated: Bool
    public let message: String
    public init(target: String = "", authenticated: Bool = false, message: String = "等待 iAP2 会话") {
        self.target = String(target.unicodeScalars.prefix(24))
        self.authenticated = authenticated
        self.message = String(message.unicodeScalars.prefix(80))
    }
}
