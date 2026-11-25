import MapKit
import SwiftUI

/// iPhone 与 iPad 连接 Mac 后仅操作经验证的本机。
@main
struct EverywhereApp: App {
    var body: some Scene { WindowGroup { MobileView() } }
}

/// iPhone / iPad 地图和控制面板。显式选择主机与设备后才能应用坐标。
private struct MobileView: View {
    @StateObject private var model = MobileModel()
    @StateObject private var sourceProbe = LocationProbeModel()
    @StateObject private var networkProbe = NetworkProbe()
    @State private var showsDiagnostics = false
    @StateObject private var bluetooth = MobileBluetoothReceiver()
    @Environment(\.scenePhase) private var phase
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var restoreTarget: RemoteTarget?
    @State private var confirmDisconnect = false
    @State private var pairing = false
    @State private var expanded = false
    @State private var camera: MapCameraPosition = .region(.init(center: .init(latitude: 31.2304, longitude: 121.4737),
                                                               span: .init(latitudeDelta: 0.2, longitudeDelta: 0.2)))

    /// 地图或手输坐标共用 ScenarioKit 的 WGS 84 校验，任一字段无效返回 nil。
    private var draft: GeoPoint? {
        guard let lat = Double(latitude), let lon = Double(longitude) else { return nil }
        return try? GeoPoint(latitude: lat, longitude: lon)
    }

    @StateObject private var book = PlaceBook()
    @State private var browserTab: PlaceTab?
    @State private var namedPlace: BookPlace?
    @AppStorage("map.displayDatum") private var datum = MapDatum.wgs84
    @State private var satellite = false
    @State private var pins = true
    @State private var visibleRegion = MKCoordinateRegion(center: .init(latitude: 31.2304, longitude: 121.4737),
                                                          span: .init(latitudeDelta: 0.2, longitudeDelta: 0.2))
    @Environment(\.verticalSizeClass) private var verticalSize
    @Environment(\.horizontalSizeClass) private var horizontalSize

    private var placeName: String? {
        if let saved = book.favorites.first(where: { $0.point == draft }) { return saved.name }
        return namedPlace?.point == draft ? namedPlace?.name : nil
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                if geometry.size.width >= 680 && (verticalSize == .compact || horizontalSize == .regular) {
                    HStack(spacing: 0) {
                        map
                        Divider()
                        controls.frame(width: min(390, geometry.size.width * 0.46))
                    }
                } else {
                    VStack(spacing: 0) {
                        map
                        VStack(spacing: 0) {
                            Button { expanded.toggle() } label: {
                                HStack {
                                    Label("目的地与操作", systemImage: "mappin.and.ellipse")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                                }
                                .padding(.horizontal, 18).frame(minHeight: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).accessibilityValue(expanded ? "已展开" : "已收起")
                            controls
                        }
                        .frame(height: geometry.size.height * (expanded ? 0.78 : 0.53))
                        .background(MapPalette.workspace)
                    }
                }
            }
            .navigationTitle("Everywhere").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showsDiagnostics = true } label: {
                        Label("诊断", systemImage: "waveform.path.ecg").labelStyle(.titleAndIcon)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { pairing = true } label: {
                        if model.transport == .bluetooth && bluetooth.isConnected {
                            Label(bluetooth.viewingIAP2 ? (bluetooth.report?.authenticated == true ? "iAP2 已连接" : "Mac 会话") : "蓝牙已连接", systemImage: "link.circle.fill").labelStyle(.titleAndIcon)
                        } else {
                            Label(model.connected ? model.transport.rawValue : "连接设置",
                              systemImage: model.connected ? "link.circle.fill" : "desktopcomputer")
                            .labelStyle(.titleAndIcon)
                        }
                    }.accessibilityValue(model.transport == .bluetooth ? bluetooth.connectionLabel : model.linkStatus)
                }
            }
        }
        .tint(.indigo)
        .sheet(isPresented: $showsDiagnostics) {
            LocationProbeView(model: sourceProbe, network: networkProbe, canDismiss: true)
        }
        .sheet(isPresented: $pairing) { pairingSheet }
        .sheet(item: $browserTab) { tab in
            PlaceBrowser(book: book, tab: tab, region: visibleRegion, select: selectPlace)
                .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        }
        .onChange(of: phase) { _, value in if value == .active { bluetooth.refreshReport() } }
        .onChange(of: bluetooth.point) { _, point in
            guard let point else { return }
            camera = .region(.init(center: datum.display(point),
                                   span: .init(latitudeDelta: 0.025, longitudeDelta: 0.025)))
        }
        .alert(item: $restoreTarget) { target in
            let title = target.recoveryScope?.button ?? "恢复定位"
            let guide = target.recoveryScope?.instructions ?? "保持连接，等待 Mac 返回清除结果。"
            return Alert(title: Text(title + "？"), message: Text("本机 · " + guide),
                         primaryButton: .default(Text(title)) { Task { await model.submit(nil, confirmedTarget: target) } },
                         secondaryButton: .cancel(Text("取消")))
        }
        .onAppear { model.browse() }
        .onChange(of: phase) { _, phase in
            if phase == .background { sourceProbe.stop(); model.background() }
            else if phase == .active { model.browse() }
        }
    }

    /// 搜索和收藏同时移动镜头与草稿；地图手动点击清除旧地名。
    private func selectPlace(_ place: BookPlace) {
        namedPlace = place
        latitude = String(place.point.latitude)
        longitude = String(place.point.longitude)
        camera = .region(.init(center: datum.display(place.point),
                               span: .init(latitudeDelta: 0.025, longitudeDelta: 0.025)))
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera) {
                if pins {
                    ForEach(book.favorites.filter { $0.point != draft }) { place in
                        Annotation(place.name, coordinate: datum.display(place.point)) {
                            Button { selectPlace(place) } label: {
                                Image(systemName: "bookmark.fill").foregroundStyle(.indigo).padding(8).background(.regularMaterial, in: Circle())
                            }.accessibilityLabel(place.name)
                        }
                    }
                }
                if let point = bluetooth.point {
                    Marker("蓝牙位置", coordinate: datum.display(point)).tint(.indigo)
                }
                if model.transport != .bluetooth, let draft {
                    Marker(placeName ?? "待应用", coordinate: datum.display(draft)).tint(MapPalette.waypoint)
                }
            }
            .mapStyle(satellite ? .hybrid : .standard)
            .onMapCameraChange { visibleRegion = $0.region }
            .onTapGesture(coordinateSpace: .named("EverywhereMap")) { position in
                if model.transport != .bluetooth, let coordinate = proxy.convert(position, from: .named("EverywhereMap")), let point = datum.point(at: coordinate) {
                    namedPlace = nil
                    latitude = String(point.latitude)
                    longitude = String(point.longitude)
                }
            }
            .coordinateSpace(name: "EverywhereMap")
            .overlay(alignment: .topLeading) {
                PlaceMapTools(satellite: $satellite, pins: $pins) { browserTab = $0 }.padding(12)
            }
        }
    }

    /// 首页与连接设置显示同一实时通道状态，命令回执不会覆盖该状态。
    private var bluetoothConnectionLabel: some View {
        Label(bluetooth.connectionLabel, systemImage: bluetooth.isConnected ? "checkmark.circle.fill" : "antenna.radiowaves.left.and.right")
            .font(.headline)
            .foregroundStyle(bluetooth.isConnected ? Color.green : Color.secondary)
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.transport == .bluetooth {
                    bluetoothConnectionLabel
                    Text(bluetooth.status).font(.caption)
                    if !bluetooth.viewingIAP2 { DestinationCard(book: book, point: bluetooth.point, name: "蓝牙接收位置") }
                } else { DestinationCard(book: book, point: draft, name: placeName) }
                if model.connected {
                    Label(model.bindingMessage, systemImage: model.target?.available == true ? "iphone.gen3" : "link")
                        .font(.callout)
                    if let target = model.target { Text(target.detail).font(.caption).foregroundStyle(.secondary) }
                }
                sourcePanel
                PlaceShortcuts(book: book) { browserTab = $0 }
                if model.transport != .bluetooth && !model.receipt.isEmpty { Text(model.receipt).font(.footnote).textSelection(.enabled) }
                if model.transport != .bluetooth {
                    DisclosureGroup("输入经纬度") {
                        CoordinateFields(latitude: $latitude, longitude: $longitude)
                            .padding(.top, 8)
                        if draft == nil && (!latitude.isEmpty || !longitude.isEmpty) {
                            Text("请输入有效的 WGS 84 经纬度。").font(.caption)
                        }
                    }.font(.subheadline.weight(.semibold))
                        .padding(14).background(.background, in: RoundedRectangle(cornerRadius: 14))
                }
            }.padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(MapPalette.workspace)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                Group {
                    if model.connected {
                        actionButtons
                    } else {
                        Button { pairing = true } label: {
                            Label(model.transport == .bluetooth ? "蓝牙接收设置" : "连接 Mac", systemImage: "desktopcomputer")
                        }.buttonStyle(MapActionStyle())
                    }
                }.padding(.horizontal, 14).padding(.vertical, 8)
            }.background(.regularMaterial)
        }
    }

    /// 用户主动开启本机来源检测，切换连接模式时继续接收同一部手机的系统样本。
    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("本机定位来源", systemImage: "location.viewfinder")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(sourceProbe.canStop ? "停止检测" : "开始检测") {
                    if sourceProbe.canStop { sourceProbe.stop() } else { sourceProbe.start() }
                }.buttonStyle(.bordered)
            }
            Text(sourceProbe.state.rawValue).font(.caption).foregroundStyle(.secondary)
            if let sample = sourceProbe.latestObservation {
                LocationSourceReadout(sample: sample)
                if model.transport == .bluetooth, let point = bluetooth.point, let received = bluetooth.pointReceivedAt {
                    if !sample.predatesSubscription, sample.sampleTime >= received, sample.sampleAgeAtReceipt >= 0,
                       CLLocationCoordinate2DIsValid(sample.coordinate), sample.horizontalAccuracy.isFinite, sample.horizontalAccuracy >= 0 {
                        let observed = CLLocation(latitude: sample.coordinate.latitude, longitude: sample.coordinate.longitude)
                        let expected = CLLocation(latitude: point.latitude, longitude: point.longitude)
                        Text("本次系统样本距蓝牙标记 " + observed.distance(from: expected).formatted(.number.precision(.fractionLength(0))) + " 米，水平精度 ±" + sample.horizontalAccuracy.formatted(.number.precision(.fractionLength(0))) + " 米。")
                            .font(.caption)
                    } else {
                        Text("等待收到蓝牙坐标后的有效系统样本。").font(.caption)
                    }
                }
                Text("样本时间 " + sample.sampleTime.formatted(date: .numeric, time: .standard))
                    .font(.caption).foregroundStyle(.secondary)
            } else if sourceProbe.state == .unavailable {
                Text("如需检测，请在系统设置中允许本应用使用定位。").font(.footnote)
            } else if sourceProbe.state.isListening {
                Text("等待 Core Location 返回首条样本。").font(.footnote)
            }
            if let error = sourceProbe.errorMessage { Text(error).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 14))
    }

    /// 操作栏固定在当前面板底部，回执与目标可用性仍由同一个模型驱动。
    private var actionButtons: some View {
        HStack(spacing: 10) {
            LocationSendButton(recoveryAction: model.target?.recoveryScope?.button ?? "恢复定位") {
                guard let point = draft, let target = model.target else { return nil }
                let name = placeName
                let transport = model.transport
                return {
                    Task {
                        guard model.transport == transport else { return }
                        if await model.submit(point, confirmedTarget: target) { book.record(point, name: name) }
                    }
                }
            } label: { Label("应用到本机", systemImage: "location.fill") }
            .buttonStyle(MapActionStyle()).disabled(draft == nil || model.target?.needsClear == true)
            Button(model.target?.recoveryScope?.button ?? "恢复定位") { restoreTarget = model.target }.buttonStyle(MapActionStyle(prominent: false))
        }.disabled(model.busy || model.target?.available != true)
    }

    /// 发现、首配和撤销均与用户选中的主机对应；配对码只从 Mac 带外取得。
    private var pairingSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 10) {
                                ForEach(MobileModel.Transport.allCases, id: \.self) { transport in
                                    let chosen = model.transport == transport
                                    Button {
                                        if model.transport != transport { bluetooth.stop(); model.chooseTransport(transport) }
                                    } label: {
                                        HStack {
                                            Image(systemName: transport == .wifi ? "wifi" : transport == .bluetooth ? "antenna.radiowaves.left.and.right" : "cable.connector")
                                            Text(transport.rawValue).bold().fixedSize()
                                        }
                                        .padding(12).frame(maxWidth: .infinity)
                                        .foregroundStyle(chosen ? Color.indigo : .primary)
                                        .background(.indigo.opacity(chosen ? 0.14 : 0.04), in: RoundedRectangle(cornerRadius: 12))
                                    }.buttonStyle(.plain).accessibilityAddTraits(chosen ? .isSelected : [])
                                }
                            }
                            if model.transport == .wifi {
                                wifiHostFields
                            } else if model.transport == .bluetooth {
                                Text("Mac 使用 iAP2 时，点「手机扫描 Mac」查看它报告的目标设备与连接状态。普通蓝牙接收用于更新 Everywhere 的地图标记。").font(.footnote)
                            } else {
                                Text("用数据线连接 Mac。在 Mac 的「设备」页点击「连接 USB 手机」，然后在这里输入配对码并开启接收。").font(.footnote)
                            }
                        }
                    } label: { Label("连接方式", systemImage: "point.3.connected.trianglepath.dotted") }
                    if model.transport == .bluetooth {
                        GroupBox("蓝牙接收") {
                            VStack(alignment: .leading, spacing: 10) {
                                bluetoothConnectionLabel
                                Text(bluetooth.status).font(.caption)
                                if bluetooth.enabled {
                                    if !bluetooth.viewingIAP2 { Text("接收码  " + bluetooth.code).font(.title3.monospacedDigit()) }
                                    if bluetooth.scanningMacs {
                                        ForEach(bluetooth.macs.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                                            Button(bluetooth.macs[id] ?? "Mac") { bluetooth.chooseMac(id) }
                                        }
                                    }
                                    Button("关闭接收") { bluetooth.stop() }
                                } else {
                                    Button("手机扫描 Mac") { bluetooth.scanMacs() }
                                    Button("让 Mac 扫描本机") { bluetooth.start() }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 12) {
                                if !model.connected && !model.usbListening {
                                    SecureField("首次连接请输入 Mac 显示的配对码", text: $model.code)
                                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    Button(model.transport == .usb ? "开启 USB 接收" : "连接并验证 Mac") { model.connect() }
                                        .buttonStyle(MapActionStyle())
                                        .disabled((model.transport == .wifi && model.endpoint == nil) || model.busy)
                                    if model.transport == .wifi {
                                        Button("使用已保存的 USB 配对连接") { model.connectUsingUSBPairing() }
                                            .disabled(model.endpoint == nil || model.busy)
                                    }
                                } else {
                                    Button("断开连接") {
                                        if model.targets.contains(where: { $0.hasActiveLocation == true || $0.needsClear || $0.hasActiveLocation == nil }) {
                                            confirmDisconnect = true
                                        } else { model.disconnect() }
                                    }
                                    .alert("断开与 Mac 的连接？", isPresented: $confirmDisconnect) {
                                        Button("返回设备操作") { pairing = false }
                                        Button("仅断开遥控", role: .destructive) { model.disconnect() }
                                        Button("取消", role: .cancel) {}
                                    } message: { Text("断开遥控后，Mac 上的定位会话可能继续。要恢复位置，请返回设备操作，执行本机恢复。") }
                                }
                                Label(model.linkStatus, systemImage: model.connected ? "checkmark.circle.fill" : "link")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        } label: { Label("配对与状态", systemImage: "link") }
                        Button("忘记此 Mac", role: .destructive) { model.forget() }
                            .disabled(model.transport == .wifi && model.selectedHost.isEmpty)
                    }
                }.padding(16).frame(maxWidth: 520)
            }
            .textFieldStyle(.roundedBorder)
            .groupBoxStyle(MapPanelStyle())
            .frame(maxWidth: .infinity)
            .background(MapPalette.workspace)
            .navigationTitle("连接设置")
                .toolbar { Button("完成") { pairing = false } }
        }
    }

    /// 保留 Bonjour 发现及手动地址两种 Wi-Fi 入口。
    @ViewBuilder
    private var wifiHostFields: some View {
        Picker("在线 Mac", selection: Binding(get: { model.selectedHost }, set: { model.chooseHost($0) })) {
            Text("请选择").tag("")
            Text(MobileModel.manual).tag(MobileModel.manual)
            ForEach(Array(Set(model.hosts.keys).union([model.selectedHost]).subtracting(["", MobileModel.manual])).sorted(), id: \.self) {
                Text($0).tag($0)
            }
        }
        if model.selectedHost == MobileModel.manual {
            TextField("Mac 的域名或 IP 地址", text: $model.address)
                .keyboardType(.URL)
                .disabled(model.busy || model.connected)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("外部端口或本机监听端口", text: $model.port).keyboardType(.numberPad)
                .disabled(model.busy || model.connected)
        }
        if model.selectedHost != MobileModel.manual && !model.discoveryMessage.isEmpty {
            Text(model.discoveryMessage)
            Button("刷新发现") { model.restartDiscovery() }
        }
    }
}
