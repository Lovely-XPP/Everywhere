import AppKit
import SwiftUI

/// 使用包内配件证书，选择经典蓝牙目标；已配置的外部程序可继续使用。
struct IAP2ConfigurationView: View {
    @ObservedObject var session: IAP2LocationSession
    @Binding var helper: String
    @State private var showingPairing = false

    var body: some View {
        GroupBox(showingPairing ? "连接新 iPhone" : "iAP2 配件会话") {
            if showingPairing {
                IPhonePairingPanel(onClose: { showingPairing = false }) { address, name in
                    showingPairing = false
                    session.connectPhone(address: address, name: name, helper: helper)
                }
            } else {
                sessionControls
            }
        }
        .onChange(of: session.running) { _, running in
            if running { showingPairing = false }
        }
        .task(id: showingPairing) {
            guard !showingPairing else { return }
            while !Task.isCancelled {
                if !session.running { await session.refresh() }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            BluetoothActionCard(title: "连接新 iPhone", symbol: "iphone.radiowaves.left.and.right",
                                detail: "搜索附近设备并验证 iAP2 配件身份", prominent: true) {
                showingPairing = true
            }
            if session.running { Text("停止当前会话后可连接其他设备。").font(.caption) }
            if let error = session.sharingError { Text(error).foregroundStyle(.orange) }

            HStack {
                let selection = session.devices[session.address]
                ConsoleDropdown(title: "已有iPhone连接", value: selection ?? (session.devices.isEmpty ? "暂无设备" : "选择 iPhone"),
                                symbol: "iphone") {
                    ForEach(session.devices.keys.sorted(), id: \.self) { address in
                        let name = session.devices[address] ?? address
                        Button {
                            session.connectPhone(address: address, name: name, helper: helper)
                        } label: {
                            if address == session.address {
                                Label(name + " · " + address, systemImage: "checkmark")
                            } else {
                                Text(name + " · " + address)
                            }
                        }
                    }
                    if !session.address.isEmpty {
                        Divider()
                        Button("取消选择") { session.address = "" }
                    }
                }
                .disabled(session.devices.isEmpty)
                Button {
                    Task { await session.refresh(userInitiated: true) }
                } label: {
                    HStack(spacing: 5) {
                        if session.refreshingByRequest { ProgressView().controlSize(.small) }
                        else {
                            Image(systemName: "arrow.clockwise")
                                .symbolEffect(.bounce, value: session.lastManualRefresh)
                        }
                        Text(session.refreshingByRequest ? "刷新中" : "刷新")
                    }
                }
                .controlSize(.small)
                .disabled(session.refreshingByRequest)
                .accessibilityLabel("刷新已配对设备")
            }
            if let date = session.lastManualRefresh {
                Text("已刷新 \(date.formatted(date: .omitted, time: .standard)) · \(session.refreshFeedback)")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("pairedRefreshResult")
            }
            DisclosureGroup("认证程序") {
                Text(helper.isEmpty ? "使用内置 MFi 认证程序" : helper).font(.caption).textSelection(.enabled)
                Button("选择外部程序…") { chooseHelper() }
                if !helper.isEmpty { Button("使用内置程序") { helper = "" } }
            }
        }
        .disabled(session.running)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chooseHelper() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            helper = url.path
        }
    }
}


/// 设备操作共用整行点击区域，并随按压和系统禁用状态更新外观。
struct BluetoothActionCard: View {
    let title: String
    let symbol: String
    var detail: String? = nil
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(prominent ? Color.white : Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(prominent ? AnyShapeStyle(Color.indigo.gradient) : AnyShapeStyle(Color.accentColor.opacity(0.12)))
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(BluetoothCardStyle(prominent: prominent))
    }
}

/// 用系统前景色适配浅色与深色模式，主入口使用靛蓝色边框。
private struct BluetoothCardStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let tint: Color = prominent ? .indigo : .primary
        let outline = RoundedRectangle(cornerRadius: 12, style: .continuous)
        configuration.label
            .background(outline.fill(tint.opacity(configuration.isPressed ? 0.19 : prominent ? 0.10 : 0.04)))
            .overlay(outline.strokeBorder(tint.opacity(prominent ? 0.30 : 0.13)))
            .opacity(enabled ? 1 : 0.5)
    }
}
