import CoreLocation
import SwiftUI

/// 展示定位授权、监听状态、样本和接收时间、坐标、精度及来源标志。
/// App 转到后台后停止订阅；回到前台需要用户再次点击开始监听。
@MainActor
struct LocationProbeView: View {
    @ObservedObject var model: LocationProbeModel
    @ObservedObject var network: NetworkProbe
    var canDismiss = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationView {
            GeometryReader { geometry in
                ScrollView {
                    Group {
                        if geometry.size.width >= 760 {
                            HStack(alignment: .top, spacing: 18) {
                                subscriptionPanel.frame(width: min(340, geometry.size.width * 0.36))
                                samplePanel
                            }
                        } else {
                            VStack(spacing: 14) {
                                subscriptionPanel
                                samplePanel
                            }
                        }
                    }
                    networkPanel
                    notes
                }
                .padding(.horizontal, geometry.size.width >= 760 ? 24 : 16)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
                .background(Color(uiColor: .systemGroupedBackground))
            }
            .navigationTitle("定位与网络诊断")
            .toolbar {
                if canDismiss {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .onAppear { if scenePhase == .active { network.start() } }
        .onDisappear { network.stop() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { network.start() } else { network.stop() }
            if phase == .background {
                model.stop()
            }
        }
    }

    /// 前台订阅状态和权限在同一面板显示；状态来自 Core Location 回调。
    private var subscriptionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Core Location", systemImage: "waveform.path.ecg")
                .font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Text(model.state.rawValue)
                .font(.system(.title2, design: .rounded).weight(.bold))
                .accessibilityAddTraits(.isHeader)
            Button {
                if model.canStop { model.stop() } else { model.start() }
            } label: {
                Label(model.canStop ? "停止监听" : "开始监听",
                      systemImage: model.canStop ? "stop.fill" : "play.fill")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 32)
            }
            .buttonStyle(.borderedProminent).tint(.indigo)
            Divider()
            valueRow("定位权限", authorizationText)
            valueRow("精度授权", accuracyAuthorizationText)
            valueRow("监听开始 (UTC)", Self.formatTime(model.subscriptionStart))
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle").foregroundColor(.red)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    /// 最新读数优先展示坐标，样本时间、来源及有效性提示紧随其后。
    private var samplePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("最新样本", systemImage: "scope").font(.headline).accessibilityAddTraits(.isHeader)
            if let sample = model.latestObservation {
                observationRows(sample)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.largeTitle).foregroundStyle(.indigo).accessibilityHidden(true)
                    Text("尚无定位样本").font(.headline)
                    Text(model.canStop ? "等待系统返回位置" : "开始监听后，此处显示系统返回的坐标")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 22)
            }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    /// 将默认网络路径和接入点比较结果同定位样本并列，供设点前后独立取样。
    private var networkPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("网络对照", systemImage: "network").font(.headline).accessibilityAddTraits(.isHeader)
            valueRow("当前网络路径", network.route)
            if let sample = network.last {
                valueRow("取样时间 (UTC)", Self.formatTime(sample.date))
                valueRow("取样时网络", sample.route)
                valueRow("Wi-Fi 接入点", sample.comparison)
            }
            Button("读取网络样本") { network.capture() }
                .buttonStyle(.bordered).disabled(!network.ready || network.reading)
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    /// 低频说明允许按需展开，保留缓存、来源标志及数据保留的解释。
    private var notes: some View {
        DisclosureGroup("观测说明") {
            VStack(alignment: .leading, spacing: 8) {
                Text("仅在前台读取 Core Location。进入后台会停止监听，返回后可手动重新开始。")
                Text("最后一条样本保留在内存中，再次开始监听时清空。此工具不连接执行后端，不保存或上传轨迹。")
                Text("早于本轮监听的样本可能来自缓存。来源未知表示系统未提供该字段。其他 App 的实际位置需独立观察。")
            }
            .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
        }
        .padding(16).tint(.indigo)
    }

    /// 显示系统授权状态；拒绝状态也可能由系统定位服务关闭导致。
    private var authorizationText: String {
        switch model.authorization {
        case .notDetermined: return "尚未决定"
        case .restricted: return "受系统限制"
        case .denied: return "已拒绝或定位服务关闭"
        case .authorizedWhenInUse: return "使用 App 期间"
        case .authorizedAlways: return "始终允许"
        @unknown default: return "未知"
        }
    }

    /// 精度授权不等价于单条定位样本的水平精度。
    private var accuracyAuthorizationText: String {
        switch model.authorization {
        case .authorizedWhenInUse, .authorizedAlways:
            switch model.accuracyAuthorization {
            case .fullAccuracy: return "精确位置"
            case .reducedAccuracy: return "大致位置"
            @unknown default: return "未知"
            }
        default: return "未取得授权"
        }
    }

    /// 将独立样本呈现为可手工选取读数的字段。
    /// - Parameter observation: 最新回调中的观察记录。
    @ViewBuilder
    private func observationRows(_ observation: LocationObservation) -> some View {
        let coordinateIsValid = CLLocationCoordinate2DIsValid(observation.coordinate)
        VStack(alignment: .leading, spacing: 10) {
            valueRow("纬度 (°)", coordinateIsValid ? String(format: "%.8f", observation.coordinate.latitude) : "无效")
            valueRow("经度 (°)", coordinateIsValid ? String(format: "%.8f", observation.coordinate.longitude) : "无效")
        }
        .font(.system(.title3, design: .monospaced).weight(.medium))
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.indigo.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        valueRow("样本时间 (UTC)", Self.formatTime(observation.sampleTime))
        valueRow("接收时间 (UTC)", Self.formatTime(observation.receivedTime))
        valueRow("接收与样本时间差", String(format: "%.3f s", observation.sampleAgeAtReceipt))
        valueRow("水平精度", Self.formatAccuracy(observation.horizontalAccuracy))
        LocationSourceReadout(sample: observation)
        Group {
            if observation.predatesSubscription {
                Text("样本早于本次监听开始，可能为缓存位置。")
                    .foregroundColor(.orange)
            }
            if observation.sampleAgeAtReceipt < 0 {
                Text("样本时间晚于接收时间，请核对设备时钟。")
                    .foregroundColor(.orange)
            }
            if !coordinateIsValid {
                Text("坐标无效，不用于位置确认。")
                    .foregroundColor(.orange)
            }
        }
    }

    /// 以可适应窄屏和动态字号的竖排标题和值展示字段。
    private func valueRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .monospacedDigit()
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    /// 将绝对时间格式化为 UTC ISO 8601，含毫秒；nil 表示尚未记录。
    private static func formatTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    /// 水平精度以米展示；负值或非有限值视为无效。
    private static func formatAccuracy(_ accuracy: CLLocationAccuracy) -> String {
        guard accuracy.isFinite, accuracy >= 0 else { return "无效" }
        return String(format: "%.1f m", accuracy)
    }

}
