import MapKit
import SwiftUI
#if SWIFT_PACKAGE
import ScenarioKit
#endif

/// 地图上打开搜索、收藏或最近使用的入口。
public enum PlaceTab: String, CaseIterable, Identifiable {
    case search = "搜索", favorites = "收藏", recent = "最近"
    public var id: Self { self }
    public var symbol: String {
        switch self {
        case .search: return "magnifyingglass"
        case .favorites: return "bookmark"
        case .recent: return "clock"
        }
    }
}

/// 两个平台共用的地图工具栏；图层菜单控制普通地图、卫星图及收藏标记。
public struct PlaceMapTools: View {
    @AppStorage("map.displayDatum") private var datum = MapDatum.wgs84
    @Binding private var satellite: Bool
    @Binding private var pins: Bool
    private let open: (PlaceTab) -> Void

    public init(satellite: Binding<Bool>, pins: Binding<Bool>, open: @escaping (PlaceTab) -> Void) {
        _satellite = satellite
        _pins = pins
        self.open = open
    }

    public var body: some View {
        HStack(spacing: 0) {
            Button { open(.search) } label: {
                Label("搜索地点或地址", systemImage: "magnifyingglass")
                    .font(.subheadline.weight(.medium)).padding(.horizontal, 15)
                    .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                    .contentShape(Rectangle())
            }.accessibilityLabel("搜索地点")
            Divider().frame(height: 22)
            Menu {
                Picker("底图坐标系", selection: $datum) {
                    ForEach(MapDatum.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("卫星地图", isOn: $satellite)
                Toggle("在地图上显示收藏", isOn: $pins)
            } label: {
                Image(systemName: satellite ? "square.3.layers.3d.top.filled" : "square.3.layers.3d")
                    .frame(width: 46, height: 46).contentShape(Rectangle())
            }.menuStyle(.button).accessibilityLabel("地图图层").help("地图图层")
        }
        .buttonStyle(.plain).frame(maxWidth: 310)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.primary.opacity(0.10)) }
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
    }
}

/// 显式命名当前草稿。再次收藏同一坐标时编辑原条目。
public struct SavePlaceButton: View {
    @ObservedObject private var book: PlaceBook
    private let point: GeoPoint?
    private let suggestion: String?
    @State private var editing: BookPlace?
    @State private var name = ""
    @State private var presented = false

    public init(book: PlaceBook, point: GeoPoint?, suggestion: String?) {
        self.book = book
        self.point = point
        self.suggestion = suggestion
    }

    public var body: some View {
        let saved = book.favorites.first { $0.point == point }
        Button {
            guard let point else { return }
            name = saved?.name ?? suggestion ?? ""
            editing = saved ?? BookPlace("", at: point)
            presented = true
        } label: {
            Label(saved == nil ? "收藏" : "已收藏", systemImage: saved == nil ? "bookmark" : "bookmark.fill")
        }
        .disabled(point == nil)
        .alert("收藏名称", isPresented: $presented) {
            TextField("地点名称", text: $name)
            Button("取消", role: .cancel) {}
            Button("保存") { if let editing { book.save(name, at: editing.point) } }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

/// 本地地点簿与 MapKit 地名搜索。回调只更新地图草稿，执行操作由外层确认。
public struct PlaceBrowser: View {
    @AppStorage("map.displayDatum") private var datum = MapDatum.wgs84
    @ObservedObject private var book: PlaceBook
    @Environment(\.dismiss) private var dismiss
    @State private var tab: PlaceTab
    @State private var query = ""
    @State private var results: [BookPlace] = []
    @State private var activeSearch: MKLocalSearch?
    @State private var searchMessage = ""
    @State private var clearHistory = false
    @State private var rename: BookPlace?
    @State private var newName = ""
    @State private var renaming = false
    private let region: MKCoordinateRegion
    private let select: (BookPlace) -> Void

    public init(book: PlaceBook, tab: PlaceTab, region: MKCoordinateRegion, select: @escaping (BookPlace) -> Void) {
        self.book = book
        _tab = State(initialValue: tab)
        self.region = region
        self.select = select
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "map.fill").foregroundStyle(.white)
                    .frame(width: 38, height: 38).background(MapPalette.violet.gradient, in: RoundedRectangle(cornerRadius: 12))
                Text("地点簿").font(.system(.title2, design: .rounded, weight: .bold))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("关闭地点簿")
            }
            MapTabs(PlaceTab.allCases, selection: $tab, title: { $0.rawValue }, icon: { $0.symbol })
            if tab == .search {
                HStack {
                    TextField("地点、地址或地标", text: $query)
                        .textFieldStyle(.roundedBorder).onSubmit { search() }
                    Button("搜索") { search() }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .onChange(of: query) { _, _ in resetSearch() }
            }
            if tab == .recent && !book.recent.isEmpty {
                Button("清空最近使用", role: .destructive) { clearHistory = true }.font(.caption)
            }
            if items.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    if activeSearch != nil { ProgressView() }
                    else { Image(systemName: icon).font(.title).foregroundStyle(.indigo)
                        .frame(width: 72, height: 72).background(.indigo.opacity(0.11), in: RoundedRectangle(cornerRadius: 22)) }
                    Text(emptyText).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { place in
                            HStack {
                                Button {
                                    select(place)
                                    dismiss()
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: icon).foregroundStyle(.indigo)
                                            .frame(width: 34, height: 34).background(.indigo.opacity(0.10), in: Circle())
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(place.name).font(.headline)
                                            if let address = place.address, !address.isEmpty {
                                                Text(address).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                            }
                                            Text(place.coordinates).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if tab == .favorites {
                                    Menu {
                                        Button("重命名") {
                                            rename = place
                                            newName = place.name
                                            renaming = true
                                        }
                                        Button("移除收藏", role: .destructive) { book.removeFavorite(place.id) }
                                    } label: { Image(systemName: "ellipsis.circle") }
                                    .accessibilityLabel("管理" + place.name)
                                }
                            }.padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(20)
        .background(MapPalette.workspace)
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 460, minHeight: 380, idealHeight: 450)
        #endif
        .onDisappear { resetSearch() }
        .alert("重命名收藏", isPresented: $renaming) {
            TextField("地点名称", text: $newName)
            Button("取消", role: .cancel) {}
            Button("保存") { if let rename { book.save(newName, at: rename.point) } }
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .confirmationDialog("清空本机最近使用的地点？", isPresented: $clearHistory, titleVisibility: .visible) {
            Button("清空最近使用", role: .destructive) { book.clearRecent() }
        }
    }

    private var items: [BookPlace] {
        switch tab { case .search: return results; case .favorites: return book.favorites; case .recent: return book.recent }
    }
    private var icon: String {
        switch tab { case .search: return "magnifyingglass"; case .favorites: return "bookmark"; case .recent: return "clock" }
    }
    private var emptyText: String {
        switch tab {
        case .search: return searchMessage.isEmpty ? "输入地名或地址，搜索地图上的地点" : searchMessage
        case .favorites: return "在地图上选点，点“收藏”并为地点命名"
        case .recent: return "成功应用的地点会出现在这里"
        }
    }

    /// 更换关键词或关闭面板时取消旧查询，过期结果不能覆盖新列表。
    private func resetSearch() {
        activeSearch?.cancel()
        activeSearch = nil
        results = []
        searchMessage = ""
    }

    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        resetSearch()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = term
        request.region = region
        let search = MKLocalSearch(request: request)
        activeSearch = search
        searchMessage = "正在搜索…"
        Task { @MainActor in
            do {
                let response = try await search.start()
                guard activeSearch === search else { return }
                results = response.mapItems.compactMap { item in
                    let coordinate: CLLocationCoordinate2D
                    let address: String?
                    if #available(macOS 26, iOS 26, *) {
                        coordinate = item.location.coordinate
                        address = item.address?.fullAddress
                    } else {
                        coordinate = item.placemark.coordinate
                        address = item.placemark.title
                    }
                    guard let point = datum.point(at: coordinate) else { return nil }
                    return BookPlace(item.name ?? term, at: point, address: address)
                }
                searchMessage = "没有找到地点，试试城市名和街道名"
            } catch {
                guard activeSearch === search else { return }
                searchMessage = (error as? MKError)?.code == .placemarkNotFound ? "没有找到匹配地点" : "搜索失败 · " + error.localizedDescription
            }
            activeSearch = nil
        }
    }
}
