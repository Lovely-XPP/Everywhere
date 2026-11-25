import CoreLocation
import Foundation
#if SWIFT_PACKAGE
import ScenarioKit
#endif

/// 地图接口所用的坐标系；协议、手输和地点簿始终使用 WGS 84 十进制度。
public enum MapDatum: String, CaseIterable {
    case wgs84 = "WGS 84"
    case gcj02 = "GCJ-02（大陆偏移底图）"

    /// 将地点簿中的真实经纬度投到所选地图坐标系。GCJ 采用公开近似公式，仅用于偏移底图。
    public func display(_ point: GeoPoint) -> CLLocationCoordinate2D {
        let lat = point.latitude, lon = point.longitude
        guard self == .gcj02, (0.8293...55.8271).contains(lat), (72.004...137.8347).contains(lon) else {
            return .init(latitude: lat, longitude: lon)
        }
        let x = lon - 105, y = lat - 35
        let pi = Double.pi
        func waves(_ v: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> Double {
            (a * sin(v * b * pi) + c * sin(v * d * pi)) * 2 / 3
        }
        let common = waves(x, 20, 6, 20, 2)
        let dy = -100 + 2*x + 3*y + 0.2*y*y + 0.1*x*y + 0.2*sqrt(abs(x))
            + common + waves(y, 20, 1, 40, 1/3) + waves(y, 160, 1/12, 320, 1/30)
        let dx = 300 + x + 2*y + 0.1*x*x + 0.1*x*y + 0.1*sqrt(abs(x))
            + common + waves(x, 20, 1, 40, 1/3) + waves(x, 150, 1/12, 300, 1/30)
        let radians = lat * pi / 180
        let eccentricity = 0.006693421622965943
        let radius = 6378245.0
        let factor = 1 - eccentricity * pow(sin(radians), 2)
        return .init(latitude: lat + dy * 180 * factor * sqrt(factor) / (radius * (1-eccentricity) * pi),
                     longitude: lon + dx * 180 * sqrt(factor) / (radius * cos(radians) * pi))
    }

    /// 将地图点击或搜索坐标转换为 WGS 84，使用正向残差迭代反算；非法输入返回 nil。
    public func point(at coordinate: CLLocationCoordinate2D) -> GeoPoint? {
        guard var point = try? GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude) else { return nil }
        guard self == .gcj02 else { return point }
        for _ in 0..<8 {
            let projected = display(point)
            let dy = coordinate.latitude - projected.latitude
            let dx = coordinate.longitude - projected.longitude
            if max(abs(dx), abs(dy)) < 1e-9 { return point }
            guard let next = try? GeoPoint(latitude: point.latitude + dy, longitude: point.longitude + dx) else { return nil }
            point = next
        }
        return point
    }
}
