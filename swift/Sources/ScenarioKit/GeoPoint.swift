import Foundation

/// 一个经过校验的 WGS 84 固定位置，可跨任务传递或导出为 GPX 调试点。
public struct GeoPoint: Codable, Equatable, Sendable {
    /// WGS 84 纬度，单位为度，有效范围为 -90 到 90（含端点）。
    public let latitude: Double

    /// WGS 84 经度，单位为度，有效范围为 -180 到 180（含端点）。
    public let longitude: Double

    /// 描述坐标校验失败的原因；非有限数值也视为超出范围。
    public enum ValidationError: LocalizedError, Equatable, Sendable {
        /// 纬度不是有限数值，或超出有效范围。
        case latitudeOutOfRange

        /// 经度不是有限数值，或超出有效范围。
        case longitudeOutOfRange

        /// 返回可向用户展示的坐标错误说明。
        public var errorDescription: String? {
            switch self {
            case .latitudeOutOfRange:
                return "纬度必须是 -90 到 90 之间的有限数值。"
            case .longitudeOutOfRange:
                return "经度必须是 -180 到 180 之间的有限数值。"
            }
        }
    }

    /// 创建一个不可变的 WGS 84 坐标。
    /// - Parameters:
    ///   - latitude: 纬度，单位为度。
    ///   - longitude: 经度，单位为度。
    /// - Throws: 数值非有限或超出对应坐标范围时，抛出 ``ValidationError``。
    public init(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, (-90...90).contains(latitude) else {
            throw ValidationError.latitudeOutOfRange
        }
        guard longitude.isFinite, (-180...180).contains(longitude) else {
            throw ValidationError.longitudeOutOfRange
        }
        self.latitude = latitude
        self.longitude = longitude
    }

    /// 从本地地点簿读取十进制度坐标，同时执行正常构造时的范围校验。
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(latitude: fields.decode(Double.self, forKey: .latitude),
                      longitude: fields.decode(Double.self, forKey: .longitude))
    }

    /// 生成可保存为 UTF-8 `.gpx` 文件的 GPX 1.1 单航点文本，用于 Xcode 自有 App 定位调试对照。
    /// GPX 经度的上限不含 180 度，因此将 180 度导出为地理位置等价的 -180 度。
    public var gpx: String {
        let gpxLongitude = longitude == 180 ? -180 : longitude
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="VirtualLocation" xmlns="http://www.topografix.com/GPX/1/1">
            <wpt lat="\(Self.decimalString(latitude))" lon="\(Self.decimalString(gpxLongitude))" />
        </gpx>
        """
    }

    /// 将有限数值转换为 GPX 使用的十进制文本；保留 Double 的可往返精度，不使用指数记法。
    /// - Parameter value: 已通过坐标校验的有限数值，单位为度。
    /// - Returns: 使用句点作为小数分隔符的十进制文本。
    private static func decimalString(_ value: Double) -> String {
        let text = String(value)
        let parts = text.split(separator: "e", maxSplits: 1)
        guard parts.count == 2, let exponent = Int(parts[1]) else { return text }

        let negative = parts[0].first == "-"
        let magnitude = negative ? parts[0].dropFirst() : parts[0]
        let mantissa = magnitude.split(separator: ".", omittingEmptySubsequences: false)
        let digits = mantissa.joined()
        let decimalIndex = mantissa[0].count + exponent
        let sign = negative ? "-" : ""

        if decimalIndex <= 0 {
            return sign + "0." + String(repeating: "0", count: -decimalIndex) + digits
        }
        if decimalIndex >= digits.count {
            return sign + digits + String(repeating: "0", count: decimalIndex - digits.count)
        }
        let separator = digits.index(digits.startIndex, offsetBy: decimalIndex)
        return sign + String(digits[..<separator]) + "." + String(digits[separator...])
    }
}
