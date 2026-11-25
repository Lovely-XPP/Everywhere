import XCTest
import ScenarioKit

/// 验证固定点的坐标范围、错误条件和 GPX 调试点输出，不依赖真实设备。
final class GeoPointTests: XCTestCase {
    /// 有效范围含端点，且校验不改变输入值。
    func testCoordinateBounds() throws {
        let minimum = try GeoPoint(latitude: -90, longitude: -180)
        XCTAssertEqual(minimum.latitude, -90)
        XCTAssertEqual(minimum.longitude, -180)

        let maximum = try GeoPoint(latitude: 90, longitude: 180)
        XCTAssertEqual(maximum.latitude, 90)
        XCTAssertEqual(maximum.longitude, 180)

        let origin = try GeoPoint(latitude: 0, longitude: 0)
        XCTAssertEqual(origin, try GeoPoint(latitude: 0, longitude: 0))
    }

    /// 单独检验越界纬度及非有限纬度。
    func testInvalidLatitude() {
        for latitude in [-90.1, 90.1, .infinity, -.infinity, .nan] {
            XCTAssertThrowsError(try GeoPoint(latitude: latitude, longitude: 0)) {
                XCTAssertEqual($0 as? GeoPoint.ValidationError, .latitudeOutOfRange)
            }
        }
    }

    /// 单独检验越界经度及非有限经度。
    func testInvalidLongitude() {
        for longitude in [-180.1, 180.1, .infinity, -.infinity, .nan] {
            XCTAssertThrowsError(try GeoPoint(latitude: 0, longitude: longitude)) {
                XCTAssertEqual($0 as? GeoPoint.ValidationError, .longitudeOutOfRange)
            }
        }
    }

    /// GPX 携带单个航点，包含版本、命名空间和坐标。
    func testGPXWaypoint() throws {
        let point = try GeoPoint(latitude: 31.25, longitude: -121.5)
        XCTAssertEqual(point.gpx, """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="VirtualLocation" xmlns="http://www.topografix.com/GPX/1/1">
            <wpt lat="31.25" lon="-121.5" />
        </gpx>
        """)
    }

    /// GPX 对 180 度使用等价的 -180 度表示，且不修改坐标模型。
    func testGPXLongitudeAtAntimeridian() throws {
        let point = try GeoPoint(latitude: 0, longitude: 180)
        XCTAssertTrue(point.gpx.contains("lon=\"-180.0\""))
        XCTAssertEqual(point.longitude, 180)
    }

    /// GPX 小数采用非指数记法。
    func testGPXSmallCoordinatesUseDecimalNotation() throws {
        let point = try GeoPoint(latitude: 1.25e-7, longitude: -3.5e-8)
        XCTAssertTrue(point.gpx.contains("lat=\"0.000000125\""))
        XCTAssertTrue(point.gpx.contains("lon=\"-0.000000035\""))
    }
}
