import Foundation
import PlaceKit
import ScenarioKit
import XCTest

/// 使用独立的本机偏好域验证收藏与使用记录的读写。
final class PlaceBookTests: XCTestCase {
    /// 已知北京参考点验证正向偏移；反算、海外点和原生底图均应保留真实坐标。
    func testMapDatumConversion() throws {
        let point = try GeoPoint(latitude: 39.908823, longitude: 116.397470)
        let mapped = MapDatum.gcj02.display(point)
        XCTAssertEqual(mapped.latitude, 39.910226, accuracy: 0.00001)
        XCTAssertEqual(mapped.longitude, 116.403714, accuracy: 0.00001)
        let back = try XCTUnwrap(MapDatum.gcj02.point(at: mapped))
        XCTAssertEqual(back.latitude, point.latitude, accuracy: 1e-8)
        XCTAssertEqual(back.longitude, point.longitude, accuracy: 1e-8)
        XCTAssertEqual(MapDatum.wgs84.point(at: MapDatum.wgs84.display(point)), point)
        let overseas = try GeoPoint(latitude: -33.86, longitude: 151.2)
        XCTAssertEqual(MapDatum.gcj02.point(at: MapDatum.gcj02.display(overseas)), overseas)
    }

    @MainActor
    func testFavoriteRenameRelaunchAndDelete() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let point = try GeoPoint(latitude: -33.8688, longitude: 151.2093)
        let book = PlaceBook(defaults: defaults)
        book.save("   ", at: point)
        XCTAssertTrue(book.favorites.isEmpty)
        book.save(" 悉尼 ", at: point)
        let original = try XCTUnwrap(book.favorites.first)
        XCTAssertEqual(original.name, "悉尼")
        book.save("歌剧院", at: point)
        book.record(point, name: nil)
        let reopened = PlaceBook(defaults: defaults)
        XCTAssertEqual(reopened.favorites.map(\.id), [original.id])
        XCTAssertEqual(reopened.favorites.map(\.name), ["歌剧院"])
        XCTAssertEqual(reopened.recent.map(\.point), [point])
        reopened.removeFavorite(original.id)
        XCTAssertEqual(reopened.recent.count, 1)
        XCTAssertTrue(PlaceBook(defaults: defaults).favorites.isEmpty)
    }

    @MainActor
    func testRecentLimitDedupAndClearPreserveFavorites() async throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let book = PlaceBook(defaults: defaults)
        for latitude in 0...25 {
            book.record(try GeoPoint(latitude: Double(latitude), longitude: 0), name: nil)
        }
        let point = try GeoPoint(latitude: 8, longitude: 0)
        book.record(point, name: "再访")
        XCTAssertEqual(book.recent.count, 20)
        XCTAssertEqual(book.recent.first?.point, point)
        XCTAssertEqual(book.recent.filter { $0.point == point }.count, 1)
        book.save("常用", at: point)
        book.clearRecent()
        let reopened = PlaceBook(defaults: defaults)
        XCTAssertTrue(reopened.recent.isEmpty)
        XCTAssertEqual(reopened.favorites.map(\.point), [point])
    }
}
