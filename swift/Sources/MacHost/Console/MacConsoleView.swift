import AppKit
import Combine
import CoreLocation
import HostSession
import MapKit
import RemoteControl
import PlaceKit
import ScenarioKit
import SwiftUI

/// 显示地图草稿、USB 真机选择和独立于位置观测的工具回执。
@MainActor
struct MacConsoleView: View {
    @ObservedObject var model: MacConsoleModel
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737),
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        )
    )

    @StateObject private var iap2 = IAP2LocationSession()
    @AppStorage("iap2.authHelper") private var iap2Helper = ""
    @AppStorage("iap2.positionJitter") private var positionJitter = true
    @StateObject private var book = PlaceBook()
    @State private var browserTab: PlaceTab?
    @State private var namedPlace: BookPlace?
    @AppStorage("map.displayDatum") private var datum = MapDatum.wgs84
    @State private var satellite = false
    @State private var pins = true
    @State private var visibleRegion = MKCoordinateRegion(center: .init(latitude: 31.2304, longitude: 121.4737),
                                                          span: .init(latitudeDelta: 0.5, longitudeDelta: 0.5))
    /// 窗口持有遥控主机，切换设备面板时继续维护 Wi-Fi 和 USB 连接。
    @StateObject private var remoteHost = RemoteHost()
    @State private var restoreTarget: RemoteTarget?
    @State private var choosingMode = true
    @State private var tappedCoordinate: CLLocationCoordinate2D?
    @State private var section: InspectorSection = .place

    /// 地图与当前设备会话由三个页面共享。
    private enum InspectorSection: String, CaseIterable {
        case place = "地点"
        case devices = "设备"
        case session = "会话"
        var symbol: String {
            switch self {
            case .place: return "map"
            case .devices: return "externaldrive.connected.to.line.below"
            case .session: return "waveform.path.ecg"
            }
        }
    }

    private var placeName: String? {
        if let saved = book.favorites.first(where: { $0.point == model.draftPoint }) { return saved.name }
        return namedPlace?.point == model.draftPoint ? namedPlace?.name : nil
    }

    var body: some View {
        Group {
            if choosingMode { modeChooser }
            else { workspace }
        }
        .buttonStyle(ConsoleButtonStyle())
        .textFieldStyle(ConsoleFieldStyle())
        .toggleStyle(ConsoleToggleStyle())
        .disclosureGroupStyle(ConsoleDisclosureStyle())
        .onChange(of: datum) { old, new in
            guard let tappedCoordinate, let previous = old.point(at: tappedCoordinate),
                  previous == model.draftPoint, let corrected = new.point(at: tappedCoordinate) else { return }
            model.selectMapPoint(MapDatum.wgs84.display(corrected))
        }
        .frame(minWidth: 800, minHeight: 560)
    }

    private var modeChooser: some View {
        VStack(alignment: .leading, spacing: 28) {
            Text("选择定位模式").font(.system(size: 32, weight: .semibold, design: .rounded))
            HStack(spacing: 18) {
                modeCard("蓝牙模式", detail: "连接 iAP2 配件会话或手机 Everywhere App", symbol: "antenna.radiowaves.left.and.right", tint: .indigo, mode: .iap2)
                modeCard("软件模拟模式", detail: "自动识别 USB 和 Wi-Fi 设备", symbol: "cable.connector", tint: .teal, mode: .automatic)
            }
            Picker("选点底图坐标系", selection: $datum) {
                ForEach(MapDatum.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.consolePicker("选点底图坐标系", value: datum.rawValue, symbol: "map").frame(width: 200)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [MapPalette.desktopWash, MapPalette.workspace], startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func modeCard(_ title: String, detail: String, symbol: String, tint: Color, mode: ConsoleBackendMode) -> some View {
        Button {
            model.changeBackendMode(mode)
            guard model.backendMode == mode else { return }
            section = .devices
            choosingMode = false
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(tint)
                Spacer(minLength: 16)
                HStack {
                    Text(title).font(.title2.bold())
                    Spacer()
                    Image(systemName: "arrow.right").foregroundStyle(tint)
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            .padding(24).frame(maxWidth: 360, minHeight: 176, maxHeight: 176, alignment: .leading)
            .background(MapPalette.desktopSurface, in: RoundedRectangle(cornerRadius: 20))
            .overlay { RoundedRectangle(cornerRadius: 20).stroke(tint.opacity(0.22)) }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private var workspace: some View {
        HSplitView {
            mapPanel
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 0) {
                inspectorHeader
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch section {
                        case .place:
                            DestinationCard(book: book, point: model.draftPoint, name: placeName)
                            PlaceShortcuts(book: book) { browserTab = $0 }
                            coordinatePanel
                        case .devices:
                            if model.backendMode.usesBluetoothWorkspace {
                                bluetoothConnectionPanel
                                if model.backendMode == .iap2 {
                                    IAP2ConfigurationView(session: iap2, helper: $iap2Helper)
                                } else {
                                    devicePanel
                                }
                            } else {
                                devicePanel
                                DisclosureGroup("高级连接设置") { backendPanel }
                                RemoteHostPanel(model: model, host: remoteHost)
                            }
                        case .session:
                            if model.backendMode == .iap2 { Text(iap2.status) } else { statusPanel }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: .infinity)
                Group {
                    if model.backendMode == .iap2 {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(iap2.status, systemImage: iap2.readyToSend ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right").font(.callout)
                            Toggle("发送位置随机抖动（半径 5 米）", isOn: $positionJitter)
                                .disabled(iap2.updatingPoint)
                            if iap2.running, let sent = iap2.acknowledgedPoint {
                                Text(String(format: "已获回执的坐标  %.8f, %.8f", sent.latitude, sent.longitude))
                                    .font(.caption).monospacedDigit()
                            }
                            HStack {
                                LocationSendButton(recoveryAction: "停止会话") {
                                    guard let point = model.draftPoint else { return nil }
                                    return iap2.preparePointSend(point, jitter: positionJitter)
                                } label: {
                                    Label(iap2.needsResume ? "确认选点并继续发送" : "发送地图选点", systemImage: "location.fill")
                                }
                                .buttonStyle(MapActionStyle())
                                .disabled(model.draftPoint == nil || !iap2.readyToSend)
                                Button(iap2.requestedPoint == nil ? "断开连接" : "停止会话") { iap2.stop() }
                                    .buttonStyle(MapActionStyle(prominent: false))
                                    .disabled(!iap2.running || iap2.stopping)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(MapPalette.desktopSurface, in: RoundedRectangle(cornerRadius: 16))
                        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08)) }
                    } else { commandBar }
                }.padding([.horizontal, .bottom], 12)
            }
            .frame(minWidth: 350, idealWidth: 390, maxWidth: 470, maxHeight: .infinity)
            .background {
                LinearGradient(stops: [
                    .init(color: MapPalette.desktopWash, location: 0),
                    .init(color: MapPalette.workspace, location: 0.52),
                    .init(color: MapPalette.workspace, location: 1)
                ], startPoint: .topTrailing, endPoint: .bottomLeading)
            }
        }
        .groupBoxStyle(MapPanelStyle())
        .tint(.indigo)
        .sheet(item: $browserTab) { tab in
            PlaceBrowser(book: book, tab: tab, region: visibleRegion, select: selectPlace)
        }
        .alert(item: $restoreTarget) { target in
            let scope = target.recoveryScope ?? .device
            return Alert(title: Text(scope.button + "？"),
                         message: Text("目标设备：" + (model.devices[target.id]?.name ?? target.id) + "\n" + scope.instructions),
                         primaryButton: .default(Text(scope.button)) { Task { await model.restore(target) } },
                         secondaryButton: .cancel(Text("取消")))
        }
        .frame(minWidth: 800, minHeight: 560)
        .onChange(of: model.backendMode, initial: true) { _, mode in iap2.shareStatus(mode == .iap2) }
        .task(id: model.backendMode) {
            guard [.automatic, .modern].contains(model.backendMode) else { return }
            while !Task.isCancelled {
                if model.backendMode == .modern { await model.refreshManualConnections() }
                else { await model.refreshDevices() }
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
        .task(id: model.backendMode) {
            guard model.usesPortableDiscovery else { return }
            while !Task.isCancelled {
                await model.refreshNearbyDevices()
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
            }
        }
        .onDisappear { iap2.shareStatus(false); iap2.stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in iap2.stop() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            iap2.stop()
            Task { await model.invalidateConnectionsForSleep() }
        }
    }

    /// 检查器顶部的页面选择在内容滚动时保持可见。
    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "location.fill")
                    .font(.headline).foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(MapPalette.violet.gradient, in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                Text(model.backendMode.usesBluetoothWorkspace ? "蓝牙模式" : "软件模拟模式").font(.system(.title3, design: .rounded, weight: .semibold))
                Spacer()
                Button("切换模式") {
                    if model.backendMode.isBluetooth { model.changeBackendMode(.automatic) }
                    choosingMode = true
                }
                .disabled(iap2.running || !model.canChangeBackendMode || remoteHost.enabled || remoteHost.usbDevice != nil || remoteHost.accessingKeychain)
                .help("结束活动会话和遥控连接后可切换")
            }
            MapTabs(InspectorSection.allCases, selection: $section, title: { $0.rawValue }, icon: { $0.symbol })
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var commandTargetLabel: String {
        guard let id = model.selectedDeviceID else { return "尚未选择" }
        return [model.selectedDevice?.name ?? id, model.selectedDevice?.isAvailable == true ? model.selectedDevice?.transportLabel : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// 固定底栏展示实际命令接收方，点击摘要可查看完整会话回执。
    private var commandBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "scope").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("命令目标").font(.caption).foregroundStyle(.secondary)
                    Text(commandTargetLabel)
                        .font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                        .help(model.selectedDeviceID ?? "请先在设备页准备目标")
                }
                Spacer(minLength: 6)
                Button("选择设备") { section = .devices }.controlSize(.small)
            }
            if let target = model.selectedDevice, section != .session {
                Button {
                    section = .session
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: target.status == .unknown ? "exclamationmark.triangle.fill" : "clock")
                            .foregroundStyle(target.status == .unknown ? Color.orange : Color.secondary)
                        Text(target.error ?? target.feedback).lineLimit(3)
                        Spacer(minLength: 2)
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("查看完整会话状态")
            }
            actionPanel
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MapPalette.desktopSurface, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(0.08)) }
    }

    /// 地图仅展示并编辑草稿点；点击位置转换为经纬度，点击确认前不接触真机。
    private var mapPanel: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                if pins {
                    ForEach(book.favorites.filter { $0.point != model.draftPoint }) { place in
                        Annotation(place.name, coordinate: coordinate(for: place.point)) {
                            Button { selectPlace(place) } label: {
                                Image(systemName: "bookmark.fill").foregroundStyle(.indigo).padding(7).background(.regularMaterial, in: Circle())
                            }.buttonStyle(.plain).accessibilityLabel(place.name)
                        }
                    }
                }
                if let point = model.draftPoint {
                    Marker(placeName ?? "待应用", coordinate: coordinate(for: point)).tint(MapPalette.waypoint)
                }
            }
            .mapStyle(satellite ? .hybrid : .standard)
            .onMapCameraChange { visibleRegion = $0.region }
            .onTapGesture(coordinateSpace: .local) { location in
                if let coordinate = proxy.convert(location, from: .local), let point = datum.point(at: coordinate) {
                    tappedCoordinate = coordinate
                    namedPlace = nil
                    model.selectMapPoint(MapDatum.wgs84.display(point))
                }
            }
            .overlay(alignment: .topLeading) {
                PlaceMapTools(satellite: $satellite, pins: $pins) { browserTab = $0 }.padding(16)
            }
        }
    }

    /// 地点簿只把名称与坐标载入编辑区，用户确认应用后才发给后端。
    private func selectPlace(_ place: BookPlace) {
        tappedCoordinate = nil
        namedPlace = place
        model.selectMapPoint(MapDatum.wgs84.display(place.point))
        cameraPosition = .region(.init(center: coordinate(for: place.point),
                                       span: .init(latitudeDelta: 0.025, longitudeDelta: 0.025)))
    }

    /// 两种手机 App 连接方向与移动端按钮一一对应。当前后端同时决定设备、命令及回执的去向。
    private var bluetoothConnectionPanel: some View {
        GroupBox("蓝牙连接方式") {
            VStack(alignment: .leading, spacing: 8) {
                MapTabs([ConsoleBackendMode.iap2, .bluetooth, .reverseBluetooth],
                        selection: Binding(get: { model.backendMode }, set: { model.changeBackendMode($0) }),
                        title: { $0 == .iap2 ? "iAP2" : $0 == .bluetooth ? "扫手机" : "扫 Mac" },
                        icon: { $0 == .iap2 ? "antenna.radiowaves.left.and.right" : $0 == .bluetooth ? "iphone" : "laptopcomputer" })
                .disabled(iap2.running || !model.canChangeBackendMode)
                switch model.backendMode {
                case .bluetooth:
                    Text("在手机 Everywhere 的「连接设置 → 蓝牙」点「让 Mac 扫描本机」。在下方扫描并连接手机，输入手机显示的六位接收码，即可更新手机 App 地图标记。")
                case .reverseBluetooth:
                    Text("先在下方开启 Mac 蓝牙广播，再在手机 Everywhere 的「连接设置 → 蓝牙」点「手机扫描 Mac」并选择本机。将手机显示的六位接收码输入 Mac，即可更新手机 App 地图标记。")
                default:
                    Text("选择已配对的 iPhone 可检测 iAP2 握手。手机 Everywhere 的「手机扫描 Mac」可查看配件会话状态。")
                }
                if iap2.running { Text("停止当前配件会话后可切换连接方式。") }
                else if !model.canChangeBackendMode { Text("操作完成并清除活动或未知会话后可切换连接方式。") }
            }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 切换后端以及选择本机已安装的 Python 解释器，不启动安装流程。
    private var backendPanel: some View {
        GroupBox("执行后端") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("连接方式", selection: Binding(
                    get: { model.backendMode },
                    set: { model.changeBackendMode($0) }
                )) {
                    Text(ConsoleBackendMode.automatic.rawValue).tag(ConsoleBackendMode.automatic)
                    Text("仅 USB（Xcode）").tag(ConsoleBackendMode.wired)
                    Text("仅 Wi-Fi（Xcode）").tag(ConsoleBackendMode.wireless)
                    Divider()
                    ForEach(ConsoleBackendMode.allCases.filter { !$0.usesBluetoothWorkspace && ![.automatic, .wired, .wireless].contains($0) }) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .consolePicker("连接方式", value: model.backendMode.rawValue, symbol: "cable.connector")
                .disabled(!model.canChangeBackendMode || remoteHost.enabled || remoteHost.usbDevice != nil || remoteHost.accessingKeychain)

                if !model.canChangeBackendMode {
                    Text("等待操作结束，或先清除所有活动及未知会话，才能切换后端。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.backendMode == .legacy {
                    Text("旧版 USB 开发定位服务实验路径，面向 iOS/iPadOS 16；需要已安装的本机工具和已挂载的开发支持。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.backendMode == .automatic {
                    Text("同一设备有两种连接时优先使用 USB。").font(.caption)
                } else if model.backendMode == .wired {
                    Text("刷新并选择已配对的 USB 设备。系统 16 使用旧版工具，17 及以上通过 Xcode 设点。若旧设备未列出，可选旧版 USB。").font(.caption)
                } else if model.backendMode == .wireless {
                    Text("需要带真机定位模拟命令的 Xcode（已核对 27.2）。在 Device Hub 配对后拔掉数据线，保持同一局域网，刷新并选择设备。").font(.caption)
                } else if model.backendMode == .simulator {
                    Text("仅列出已启动的 iOS 模拟器。").font(.caption)
                } else {
                    Button("选择已安装的 Python 可执行文件…") { choosePythonExecutable() }
                        .disabled(!model.canChangePython)
                    Text(model.modernPythonURL?.path ?? "未选择解释器")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("新解释器路径只用于后续启动 helper；不会自动中断或重放正在执行的定位。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("现代 USB 实验路径，面向 iOS/iPadOS 17.4+。需要已配置相应 Python 环境；具体版本组合待实测。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = model.configurationError {
                    errorText(error)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 仅旧版模式刷新真实 USB 设备；现代模式手动确认目标，明确区分发现与用户输入。
    private var devicePanel: some View {
        GroupBox("目标设备") {
            VStack(alignment: .leading, spacing: 8) {
                if model.backendMode == .wireless {
                    HStack {
                        TextField("iPhone 的 Wi-Fi IP", text: $model.wirelessAddress)
                        Button("验证连接") { Task { await model.checkWirelessAddress() } }
                            .disabled(model.wirelessAddress.isEmpty)
                    }.disabled(model.isBusy)
                    if let status = model.wirelessCheck { Text(status).font(.caption).textSelection(.enabled) }
                }
                if model.backendMode == .automatic {
                    ForEach(model.deviceIDs, id: \.self) { id in
                        if let device = model.devices[id] {
                            Button {
                                model.selectedDeviceID = id
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: device.transport == .usb ? "cable.connector" : "wifi")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(device.name ?? id).font(.body.weight(.medium))
                                        Text([device.isAvailable ? device.transportLabel : "离线",
                                              model.usesPortableDiscovery && device.isAvailable ? (device.observedPairing ? "已信任" : "待核对信任") : nil,
                                              String(id.suffix(8))]
                                            .compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: model.selectedDeviceID == id ? "checkmark.circle.fill" : "circle")
                                }
                                .padding(6).contentShape(Rectangle())
                            }
                            .buttonStyle(ConsoleButtonStyle())
                            .disabled(!device.isAvailable || model.isBusy)
                        }
                    }
                    if model.usesPortableDiscovery, model.selectedDevice?.transport == .usb,
                       model.selectedDevice?.isAvailable == true {
                        Button("信任设备并启用 Wi-Fi") { Task { await model.prepareSelectedWiFi() } }
                            .disabled(model.isBusy)
                        if let device = model.selectedDevice {
                            if let error = device.error { errorText(error) }
                            else if device.feedback.hasPrefix("设备已确认") { Text(device.feedback).font(.caption) }
                        }
                    }
                    HStack {
                        Button("刷新设备") { Task { await model.refreshDevices() } }
                            .disabled(model.isBusy || model.scanningConnections)
                        if model.scanningConnections { ProgressView().controlSize(.small) }
                    }
                } else if model.backendMode == .reverseBluetooth {
                    Button("开启 Mac 蓝牙广播") { model.advertiseBluetooth() }
                } else if model.backendMode != .modern {
                    Button(model.backendMode == .bluetooth ? "扫描蓝牙设备" : model.backendMode == .wireless ? "刷新无线设备" : model.backendMode == .simulator ? "刷新模拟器" : "刷新 USB 设备") {
                        Task { await model.refreshDevices() }
                    }
                    .disabled(model.isBusy)
                } else {
                    HStack {
                        TextField("设备 UDID", text: $model.manualDeviceID)
                            .font(.body.monospaced())
                            .disabled(model.isBusy)
                        Button("验证连接") { Task { await model.addManualTarget() } }
                            .disabled(!model.canAddManualTarget)
                    }
                    Text("输入目标设备的 UDID，然后验证 USB 连接。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.backendMode != .automatic {
                    Picker("设备", selection: $model.selectedDeviceID) {
                        Text("请选择目标设备").tag(nil as String?)
                        ForEach(model.deviceIDs, id: \.self) { id in
                            Text(deviceLabel(for: id))
                                .tag(Optional(id))
                        }
                    }.consolePicker("设备", value: model.selectedDeviceID.map { deviceLabel(for: $0) } ?? "请选择目标设备", symbol: "iphone")
                    .disabled(model.isBusy)
                }
                if model.backendMode == .bluetooth, let target = model.selectedDevice {
                    HStack {
                        Label(target.bluetoothLabel, systemImage: target.bluetoothConnected ? "link.circle.fill" : "antenna.radiowaves.left.and.right")
                            .font(.callout)
                        Spacer()
                        if target.bluetoothConnected {
                            Button("断开蓝牙") { model.disconnectBluetooth() }
                        } else {
                            Button("连接手机") { Task { await model.connectBluetooth() } }
                                .disabled(!target.isAvailable)
                        }
                    }
                    .disabled(model.isBusy)
                    SecureField("手机显示的六位蓝牙接收码", text: $model.bluetoothCode)
                        .disabled(model.isBusy)
                }
                if model.backendMode == .reverseBluetooth, model.selectedDevice?.isAvailable == true {
                    SecureField("手机显示的六位蓝牙接收码", text: $model.bluetoothCode).disabled(model.isBusy)
                }
                if model.usesPortableDiscovery, let warning = model.nearbyWarning {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
                Text(model.discoveryFeedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = model.discoveryError {
                    errorText(error)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 显示和编辑 WGS 84 坐标文本；地图和输入采用相同验证后的草稿点。
    private var coordinatePanel: some View {
        GroupBox("坐标 · WGS 84") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("选点底图", selection: $datum) {
                    ForEach(MapDatum.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.consolePicker("选点底图", value: datum.rawValue, symbol: "map")
                CoordinateFields(latitude: $model.latitudeText, longitude: $model.longitudeText)
                if let error = model.draftError {
                    errorText(error)
                }
                Button("在地图上查看草稿") {
                    guard let point = model.draftPoint else { return }
                    cameraPosition = .region(MKCoordinateRegion(
                        center: coordinate(for: point),
                        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                    ))
                }
                .disabled(model.draftPoint == nil)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 发出定点或清除命令；未连接、未配置或已有操作时禁用对应控制。
    private var actionPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LocationSendButton(recoveryAction: model.backendMode.recoveryScope.button) {
                    guard let point = model.draftPoint, let device = model.selectedDeviceID,
                          let session = model.selectedDevice?.sessionVersion else { return nil }
                    let name = placeName
                    let mode = model.backendMode
                    return {
                        Task {
                            guard model.backendMode == mode, model.selectedDeviceID == device,
                                  model.selectedDevice?.sessionVersion == session, model.draftPoint == point else { return }
                            if let sent = await model.applyDraft() { book.record(sent, name: name) }
                        }
                    }
                } label: { Label("发送地图选点", systemImage: "location.fill") }
                .buttonStyle(MapActionStyle())
                .disabled(!model.canApply)
                Button(model.backendMode.recoveryScope.button) {
                    restoreTarget = model.remoteTargets.first { $0.id == model.selectedDeviceID }
                }
                .buttonStyle(MapActionStyle(prominent: false))
                .disabled(!model.canClear)
            }
            if let activity = model.activity {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(activity).font(.caption)
                }
            }
        }
    }

    /// 后端回执、设备实际位置与目标 App 表现分别呈现，永不从回执推断观测成功。
    private var statusPanel: some View {
        GroupBox("会话状态") {
            VStack(alignment: .leading, spacing: 8) {
                if let target = model.selectedDevice {
                    Text(statusLabel(for: target.status))
                        .font(.headline)
                    Text(target.feedback)
                        .font(.callout)
                    if let error = target.error { errorText(error) }
                } else {
                    Text("尚未选定设备。")
                        .foregroundStyle(.secondary)
                }
                Divider()
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 9) {
                    observationRow("独立真机定位", symbol: "scope", status: "未确认")
                    observationRow("实际位置恢复", symbol: "arrow.uturn.backward", status: "未确认")
                    observationRow("其他 App 的位置", symbol: "square.stack", status: "未观察")
                }
                Text("请在目标设备独立观察定位更新和清除后的恢复。工具返回不等于目标设备已完成位置更新。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.backendMode.recoveryScope.instructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 对齐独立观测项目与结果，避免和后端回执混读。
    private func observationRow(_ title: String, symbol: String, status: String) -> some View {
        GridRow {
            Label(title, systemImage: symbol).font(.callout)
            Text(status).font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
    }

    /// 展示设备标识、可用性及待清除提示，便于用户选择仍需处理的设备。
    /// - Parameter id: 本次打开控制台后记录的设备标识。
    /// - Returns: 用于设备选择器的显示文字。
    private func deviceLabel(for id: String) -> String {
        guard let device = model.devices[id] else { return id }
        var suffix = device.isAvailable ? "" : " · 连接待确认"
        if model.backendMode == .bluetooth { suffix = " · " + device.bluetoothLabel }
        if device.status == .unknown {
            suffix += " · 结果未知"
        } else if case .accepted = device.status {
            suffix += " · 设点已回执"
        }
        if let name = device.name, name != id { return "\(name) · \(id)" + suffix }
        return id + suffix
    }

    /// - Parameter point: 已校验的 WGS 84 地理坐标，单位为度。
    /// - Returns: 按当前底图坐标系投影后的显示坐标。
    private func coordinate(for point: GeoPoint) -> CLLocationCoordinate2D {
        datum.display(point)
    }

    /// 将后端会话状态转为用户可见文案，已设点坐标取自对应命令，非当前草稿。
    /// - Parameter status: 所选会话的回执级状态。
    private func statusLabel(for status: SessionStatus) -> String {
        switch status {
        case .idle: return "空闲 · 无活动回执级会话"
        case .applying: return "设点 · 等待工具回执"
        case .clearing: return "清除 · 等待工具回执"
        case .unknown: return "设备结果未知 · 需先清除"
        case .accepted(let point):
            return "设点工具已返回：\(point.latitude), \(point.longitude)"
        }
    }

    /// 显示可复制的错误详情。
    /// - Parameter message: 当前回执、配置或连接错误说明。
    private func errorText(_ message: String) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(.red)
            .textSelection(.enabled)
    }

    /// 通过系统文件选择器让用户明确指定已存在的解释器，不安装软件或更改系统环境。
    private func choosePythonExecutable() {
        guard model.canChangePython else { return }
        let panel = NSOpenPanel()
        panel.title = "选择受信任的 Python 可执行文件"
        panel.message = "请选择已配置现代 USB 后端依赖的 Python 解释器；如使用虚拟环境，请选择该环境的 bin/python。"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.changePythonURL(url) }
    }
}


/// 控制台次级操作采用紧凑圆角按钮，保持工具栏与面板内的点击区域一致。
private struct ConsoleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.callout.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.indigo.opacity(configuration.isPressed ? 0.24 : 0.09)))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.primary.opacity(0.11)) }
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .opacity(enabled ? 1 : 0.48)
    }
}

/// 输入内容保留系统文本编辑能力，背景和边界跟随控制台色板。
private struct ConsoleFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration.textFieldStyle(.plain)
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(MapPalette.desktopInset, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.14)) }
    }
}

/// 选项使用整行点击区域和具有开关辅助功能语义的滑块。
private struct ConsoleToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack {
                configuration.label.font(.callout)
                Spacer()
                Capsule().fill(configuration.isOn ? Color.indigo : Color.secondary.opacity(0.35))
                    .frame(width: 32, height: 19)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle().fill(.white).padding(3)
                    }
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.switch) }
    }
}

/// 将已有 Picker 的选项用于系统菜单，共用可整行点击的下拉框外观。
private extension View {
    func consolePicker(_ title: String, value: String, symbol: String) -> some View {
        ConsoleDropdown(title: title, value: value, symbol: symbol) {
            self.labelsHidden().pickerStyle(.inline)
        }
    }
}

/// 收起时显示字段名和当前选择；窄面板中的长名称可通过悬停查看全文。
struct ConsoleDropdown<Options: View>: View {
    let title: String
    let value: String
    let symbol: String
    @ViewBuilder let options: () -> Options
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    var body: some View {
        Menu(content: options) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(.tint)
                    .frame(width: 26).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    Text(value).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .background(MapPalette.desktopInset, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(hovered && enabled ? Color.indigo : .primary.opacity(0.12)) }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .onHover { hovered = $0 }
        .opacity(enabled ? 1 : 0.6)
        .help(value)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

/// 折叠区让标题整行都可展开，箭头反映当前状态。
private struct ConsoleDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack {
                    configuration.label.font(.callout.weight(.semibold))
                    Spacer()
                    Image(systemName: configuration.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(ConsoleButtonStyle())
            if configuration.isExpanded { configuration.content }
        }
    }
}
