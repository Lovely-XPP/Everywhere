import SwiftUI
#if SWIFT_PACKAGE
import ScenarioKit
#endif

/// 地图工具共用的靛紫色板；橙色专用于标记待应用位置。
public enum MapPalette {
    public static let ink = Color(red: 0.09, green: 0.075, blue: 0.23)
    public static let violet = Color(red: 0.32, green: 0.24, blue: 0.74)
    /// 面板底色跟随系统明暗外观，避免地图旁的多层卡片使用同一灰度。
    public static var workspace: Color {
        #if os(macOS)
        desktopColor(light: 0xF7F7FF, dark: 0x14182B)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }
    #if os(macOS)
    /// 同一组动态颜色供控制台与地点簿使用，随窗口切换明暗模式。
    public static let desktopWash = desktopColor(light: 0xE4E6FF, dark: 0x292546)
    public static let desktopSurface = desktopColor(light: 0xFFFFFF, dark: 0x232840)
    public static let desktopInset = desktopColor(light: 0xEFF0FC, dark: 0x30344D)

    private static func desktopColor(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
    #endif
    public static let waypoint = Color(red: 1, green: 0.59, blue: 0.18)
}

/// 目的地卡片右侧的测绘刻度插画。按容器比例绘制，不参与点击和辅助功能焦点。
private struct TerrainLines: View {
    var body: some View {
        Canvas { context, size in
            let origin = CGPoint(x: size.width * 0.89, y: size.height * 0.72)
            let radius = min(size.width * 0.21, size.height * 0.60)
            for step in 1...5 {
                let r = radius * CGFloat(step) / 3
                let rect = CGRect(x: origin.x - r, y: origin.y - r, width: 2 * r, height: 2 * r)
                context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.14)), lineWidth: 0.8)
            }
            var axes = Path()
            axes.move(to: CGPoint(x: origin.x, y: 0))
            axes.addLine(to: CGPoint(x: origin.x, y: size.height))
            axes.move(to: CGPoint(x: size.width * 0.64, y: origin.y))
            axes.addLine(to: CGPoint(x: size.width, y: origin.y))
            context.stroke(axes, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [2, 5]))
            context.fill(Path(ellipseIn: CGRect(x: origin.x - 3, y: origin.y - 3, width: 6, height: 6)),
                         with: .color(MapPalette.waypoint))
        }.accessibilityHidden(true).allowsHitTesting(false)
    }
}

/// 两端共用的目的地摘要。卡片显示当前草稿坐标，收藏按钮与草稿绑定。
public struct DestinationCard: View {
    @ObservedObject private var book: PlaceBook
    private let point: GeoPoint?
    private let name: String?

    public init(book: PlaceBook, point: GeoPoint?, name: String?) {
        self.book = book
        self.point = point
        self.name = name
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("目的地", systemImage: "location.fill")
                    .font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.87))
                Spacer()
                if point != nil {
                    SavePlaceButton(book: book, point: point, suggestion: name)
                        .font(.caption.weight(.semibold)).buttonStyle(.bordered).tint(.white)
                }
            }
            Text(name ?? (point == nil ? "选择目的地" : "地图选点"))
                .font(.system(.title2, design: .rounded, weight: .bold)).foregroundStyle(.white)
                .lineLimit(2)
            if let point {
                HStack(spacing: 7) {
                    Circle().fill(MapPalette.waypoint).frame(width: 7, height: 7)
                    Text(BookPlace("", at: point).coordinates).font(.subheadline.monospacedDigit())
                }.foregroundStyle(.white)
            } else {
                Text("点按地图，或搜索地点名称").font(.subheadline).foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(.horizontal, 19).padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                LinearGradient(colors: [MapPalette.ink, Color(red: 0.17, green: 0.12, blue: 0.39), MapPalette.violet],
                               startPoint: .leading, endPoint: .trailing)
                TerrainLines()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// 自适应明暗外观的设置分组卡片。标题与内容保持各自的辅助功能语义。
public struct MapPanelStyle: GroupBoxStyle {
    @Environment(\.colorScheme) private var scheme
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.system(.headline, design: .rounded, weight: .semibold))
            configuration.content
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
        .background(MapPalette.desktopSurface, in: RoundedRectangle(cornerRadius: 15))
        #else
        .background(scheme == .dark ? Color(white: 0.145) : .white, in: RoundedRectangle(cornerRadius: 15))
        #endif
        .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.065)) }
    }
}

/// 定位主操作的靛紫色按钮。禁用时保留文字可读性，状态改变不影响按钮尺寸。
public struct MapActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    private let prominent: Bool

    public init(prominent: Bool = true) { self.prominent = prominent }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(.headline, design: .rounded, weight: .semibold)).padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .foregroundStyle(enabled ? (prominent ? Color.white : .primary) : Color.secondary)
            .background {
                if enabled && prominent {
                    LinearGradient(colors: [MapPalette.violet, Color(red: 0.40, green: 0.28, blue: 0.76)],
                                   startPoint: .leading, endPoint: .trailing)
                } else { Color.secondary.opacity(0.12) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}

/// 地点簿的两个常用入口，显示实际保存数量与最近一次成功应用的地点。
public struct PlaceShortcuts: View {
    @ObservedObject private var book: PlaceBook
    private let open: (PlaceTab) -> Void

    public init(book: PlaceBook, open: @escaping (PlaceTab) -> Void) {
        self.book = book
        self.open = open
    }

    public var body: some View {
        HStack(spacing: 9) {
            shortcut("收藏", detail: "\(book.favorites.count) 个地点", image: "bookmark.fill", color: .indigo, tab: .favorites)
            shortcut("最近使用", detail: book.recent.first?.name ?? "暂无记录", image: "clock.arrow.circlepath", color: .orange, tab: .recent)
        }
    }

    private func shortcut(_ title: String, detail: String, image: String, color: Color, tab: PlaceTab) -> some View {
        Button { open(tab) } label: {
            HStack(spacing: 8) {
                Image(systemName: image).font(.subheadline.weight(.semibold)).foregroundStyle(color)
                    .frame(width: 30, height: 30).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            #if os(macOS)
            .background(MapPalette.desktopSurface, in: RoundedRectangle(cornerRadius: 13))
            #else
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
            #endif
        }.buttonStyle(.plain)
    }
}

/// 地点簿与桌面检查器共用的页面导航；按钮向辅助功能报告当前选择。
public struct MapTabs<Item: Hashable>: View {
    @Binding private var selected: Item
    private let items: [Item]
    private let title: (Item) -> String
    private let icon: (Item) -> String

    public init(_ items: [Item], selection: Binding<Item>, title: @escaping (Item) -> String,
                icon: @escaping (Item) -> String) {
        self.items = items
        _selected = selection
        self.title = title
        self.icon = icon
    }

    public var body: some View {
        HStack(spacing: 3) {
            ForEach(items, id: \.self) { item in
                let active = item == selected
                Button { selected = item } label: {
                    Label(title(item), systemImage: icon(item))
                        .font(.subheadline.weight(active ? .semibold : .regular))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .foregroundStyle(active ? Color.primary : .secondary)
                        .background {
                            if active {
                                #if os(macOS)
                                RoundedRectangle(cornerRadius: 9).fill(MapPalette.desktopSurface)
                                #else
                                RoundedRectangle(cornerRadius: 9).fill(.background)
                                #endif
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(3).background(.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// WGS 84 经纬度编辑器。独立标签在输入后仍然可见，大字号时自动改为上下排列。
public struct CoordinateFields: View {
    @Binding private var latitude: String
    @Binding private var longitude: String
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(latitude: Binding<String>, longitude: Binding<String>) {
        _latitude = latitude
        _longitude = longitude
    }

    public var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout(spacing: 8))
        layout {
            field("纬度", range: "−90 … 90", text: $latitude)
            field("经度", range: "−180 … 180", text: $longitude)
        }
    }

    private func field(_ title: String, range: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            TextField(range, text: text)
                .font(.body.monospacedDigit()).textFieldStyle(.plain)
                .accessibilityLabel(title)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
        .background(MapPalette.desktopInset, in: RoundedRectangle(cornerRadius: 10))
        #else
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        #endif
    }
}
