import Combine
import Foundation
#if SWIFT_PACKAGE
import ScenarioKit
#endif

/// 用户为一个 WGS 84 坐标保留的名称；地点标识在重命名和重启之后保持稳定。
public struct BookPlace: Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public let point: GeoPoint
    /// 搜索服务返回的地址，手工草稿及没有地址的结果为 nil。
    public let address: String?

    public init(_ name: String, at point: GeoPoint, id: UUID = UUID(), address: String? = nil) {
        self.id = id
        self.name = name
        self.point = point
        self.address = address
    }

    /// 十进制度，六位小数仅用于显示，设点使用原始精度。
    public var coordinates: String {
        String(format: "%.6f, %.6f", locale: Locale(identifier: "en_US_POSIX"), point.latitude, point.longitude)
    }
}

/// 两端复用的本机地点簿。收藏与最近应用的模拟点分别存储，不订阅定位服务。
@MainActor
public final class PlaceBook: ObservableObject {
    @Published public private(set) var favorites: [BookPlace]
    @Published public private(set) var recent: [BookPlace]
    private let defaults: UserDefaults
    private static let favoritesKey = "places.v1.favorites"
    private static let recentKey = "places.v1.recent"

    /// 从当前应用容器读取地点；测试可传入独立的偏好域。
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func load(_ key: String) -> [BookPlace] {
            guard let data = defaults.data(forKey: key) else { return [] }
            return (try? PropertyListDecoder().decode([BookPlace].self, from: data)) ?? []
        }
        favorites = load(Self.favoritesKey)
        recent = load(Self.recentKey)
    }

    /// 保存或重命名同一坐标的收藏。空白名称不写入。
    public func save(_ name: String, at point: GeoPoint) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if let index = favorites.firstIndex(where: { $0.point == point }) {
            favorites[index].name = title
        } else {
            favorites.insert(BookPlace(title, at: point), at: 0)
        }
        persist(favorites, key: Self.favoritesKey)
    }

    /// 删除指定收藏，最近使用记录仍可单独管理。
    public func removeFavorite(_ id: UUID) {
        favorites.removeAll { $0.id == id }
        persist(favorites, key: Self.favoritesKey)
    }

    /// 收到设点成功回执后调用。同一点移到首位，最多保留 20 个模拟目的地。
    public func record(_ point: GeoPoint, name: String?) {
        let previous = recent.first { $0.point == point }
        let title = favorites.first { $0.point == point }?.name ?? name ?? previous?.name ?? "地图选点"
        recent.removeAll { $0.point == point }
        recent.insert(BookPlace(title, at: point, id: previous?.id ?? UUID()), at: 0)
        recent = Array(recent.prefix(20))
        persist(recent, key: Self.recentKey)
    }

    /// 清空本机最近使用记录。
    public func clearRecent() {
        recent = []
        defaults.removeObject(forKey: Self.recentKey)
    }

    private func persist(_ places: [BookPlace], key: String) {
        if let data = try? PropertyListEncoder().encode(places) { defaults.set(data, forKey: key) }
    }
}
