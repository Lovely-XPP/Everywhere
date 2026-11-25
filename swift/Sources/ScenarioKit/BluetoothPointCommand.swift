import Foundation

/// 自有 BLE 接收端的设点与清除命令。新端点可协商带 UTC 的 NMEA RMC 载荷。
public struct BluetoothPointCommand: Equatable, Sendable {
    public static let serviceID = "B26FF64E-E453-4987-9102-A99AB34B6DB8"
    public static let reverseServiceID = "62D42C56-03CB-4895-ADB6-08B640F25F71"
    public static let receiptID = "2244D789-B54F-4736-AFA4-E98E7C54118C"
    public static let commandID = "971735A6-F422-4BB2-A924-47FB7A5385C3"

    /// 新手机在正向链路发布能力特征，在反向链路订阅此特征。
    public static let rmcID = "221C5CF2-5E82-4BB1-AB2D-48A729B9071F"

    /// 每次写入只选择一个完整载荷。容量以字节计，外层请求标识由传输层预留。
    public struct Payload: Sendable {
        let compact: Data
        let rmc: Data?

        public func data(supportsRMC: Bool, capacity: Int) -> Data {
            if supportsRMC, let rmc, rmc.count <= capacity { return rmc }
            return compact
        }
    }

    /// 保留六位接收码与清除命令，按设备能力选择坐标表示方式。
    public func payload(code: String, at date: Date = Date()) throws -> Payload {
        let compact = try encode(code: code)
        let rmc = point.map { Data([2]) + Data(code.utf8) + RMCPosition.encode($0, at: date) }
        return Payload(compact: compact, rmc: rmc)
    }

    /// nil 表示清除接收端当前蓝牙位置。
    public let point: GeoPoint?

    public init(_ point: GeoPoint?) { self.point = point }

    /// 首字节为操作，随后为六位接收码；设点另含两个大端有符号微度整数。
    public func encode(code: String) throws -> Data {
        guard Self.validCode(code) else { throw Failure.code }
        var bytes = [UInt8(point == nil ? 0 : 1)] + code.utf8
        if let point {
            for value in [point.latitude, point.longitude] {
                let bits = UInt32(bitPattern: Int32((value * 1_000_000).rounded()))
                for shift in [24, 16, 8, 0] { bytes.append(UInt8(truncatingIfNeeded: bits >> shift)) }
            }
        }
        return Data(bytes)
    }

    public static func validCode(_ code: String) -> Bool {
        code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) }
    }

    /// 先核验本轮接收码，再校验操作、完整长度和 WGS 84 范围。
    public init(data: Data, code: String) throws {
        let bytes = Array(data)
        guard bytes.count >= 7 else { throw Failure.format }
        guard Self.validCode(code), bytes[1..<7].elementsEqual(code.utf8) else { throw Failure.code }
        if bytes[0] == 0 && bytes.count == 7 { point = nil; return }
        if bytes[0] == 2 {
            point = try RMCPosition.decode(Data(bytes.dropFirst(7)))
            return
        }
        guard bytes[0] == 1 && bytes.count == 15 else { throw Failure.format }
        func degrees(_ offset: Int) -> Double {
            let bits = bytes[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return Double(Int32(bitPattern: bits)) / 1_000_000
        }
        point = try GeoPoint(latitude: degrees(7), longitude: degrees(11))
    }

    public enum Failure: Error { case code, format }
}

/// 本轮接收的应用位置，首个通过校验的 Mac 持有会话，直到手机关闭接收。
public struct BluetoothPointInbox: Sendable {
    public private(set) var point: GeoPoint?
    private var owner: UUID?

    public init() {}

    /// 从手机界面移除标记，同时保留本轮接收权和接收码。
    public mutating func clearLocalPoint() { point = nil }

    /// 拒绝无效写入时保留上次坐标；只有完成状态更新后调用者才应回复成功。
    public mutating func receive(_ data: Data, code: String, from central: UUID) throws {
        guard owner == nil || owner == central else { throw BluetoothPointCommand.Failure.code }
        let command = try BluetoothPointCommand(data: data, code: code)
        owner = central
        point = command.point
    }
}

/// Everywhere 发送的 GPRMC 语句。坐标为 WGS 84，分钟保留五位小数，时间取 UTC。
private enum RMCPosition {
    static func encode(_ point: GeoPoint, at date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let stamp = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let utc = String(format: "%02d%02d%02d", stamp.hour!, stamp.minute!, stamp.second!)
        let day = String(format: "%02d%02d%02d", stamp.day!, stamp.month!, stamp.year! % 100)
        func coordinate(_ value: Double, width: Int) -> String {
            let ticks = Int((abs(value) * 6_000_000).rounded())
            let minutes = ticks % 6_000_000
            return String(format: "%0*d%02d.%05d", width, ticks / 6_000_000, minutes / 100_000, minutes % 100_000)
        }
        let fields = ["GPRMC", utc, "A", coordinate(point.latitude, width: 2), point.latitude < 0 ? "S" : "N",
                      coordinate(point.longitude, width: 3), point.longitude < 0 ? "W" : "E", "", "", day, "", "", "S"]
        let body = fields.joined(separator: ",")
        let checksum = body.utf8.reduce(UInt8(0), ^)
        return Data(("$" + body + String(format: "*%02X\r\n", checksum)).utf8)
    }

    /// 验证语句边界、XOR 校验和、有效定位状态与坐标格式，拒绝越界的度或分钟。
    static func decode(_ data: Data) throws -> GeoPoint {
        let invalid = BluetoothPointCommand.Failure.format
        guard data.count >= 10, data.count <= 82, data.first == 36, data.suffix(2).elementsEqual([13, 10]),
              data.dropLast(4).last == 42 else { throw invalid }
        let body = data.dropFirst().dropLast(5)
        let hex = data.dropLast(2).suffix(2)
        guard hex.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
              UInt8(String(decoding: hex, as: UTF8.self), radix: 16) == body.reduce(UInt8(0), ^),
              body.allSatisfy({ (32...126).contains($0) }) else { throw invalid }
        let fields = String(decoding: body, as: UTF8.self).split(separator: ",", omittingEmptySubsequences: false)
        guard (12...13).contains(fields.count), fields[0] == "GPRMC", fields[2] == "A",
              fields.count == 12 || fields[12] != "N" else { throw invalid }
        func degrees(_ text: Substring, width: Int, hemisphere: Substring, positive: String, negative: String) throws -> Double {
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count <= 2, let whole = parts.first, whole.count == width + 2,
                  parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
                  let degree = Int(whole.prefix(width)),
                  let minutes = Double(text.dropFirst(width)), minutes < 60,
                  hemisphere == positive || hemisphere == negative else { throw invalid }
            let value = Double(degree) + minutes / 60
            return hemisphere == negative ? -value : value
        }
        return try GeoPoint(latitude: degrees(fields[3], width: 2, hemisphere: fields[4], positive: "N", negative: "S"),
                            longitude: degrees(fields[5], width: 3, hemisphere: fields[6], positive: "E", negative: "W"))
    }
}
