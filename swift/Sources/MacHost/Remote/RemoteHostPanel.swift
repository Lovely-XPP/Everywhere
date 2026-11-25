import RemoteControl
import SwiftUI

/// Mac 首次启用、显示配对凭据与撤销入口；日常设点无需操作此面板。
struct RemoteHostPanel: View {
    @ObservedObject var model: MacConsoleModel
    @ObservedObject var host: RemoteHost
    @State private var reveal = false
    @AppStorage("mac.remote.tcpPort") private var port = String(RemotePairing.networkPort)
    @AppStorage("mac.remote.bonjour") private var advertise = true

    var body: some View {
        GroupBox("手机遥控") {
            VStack(alignment: .leading, spacing: 8) {
                Label("网络遥控 · 局域网与公网", systemImage: "network").font(.subheadline.weight(.semibold))
                HStack {
                    Text("TCP 监听端口")
                    TextField("1–65535", text: $port).frame(width: 92)
                }.disabled(host.enabled || host.accessingKeychain)
                Toggle("通过 Bonjour 在局域网发现", isOn: $advertise)
                    .disabled(host.enabled || host.accessingKeychain)
                Text("公网客户端使用域名或公网 IP 和外部 TCP 端口连接。Mac 在路由器后时，需将该端口转发到本机监听端口。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(host.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button(host.enabled ? "关闭网络遥控" : "开启网络遥控") {
                    reveal = false
                    if host.enabled { host.stopWiFi() } else { Task { await host.start(model, port: port, advertise: advertise) } }
                }.disabled(!host.enabled && host.accessingKeychain)
                Divider()
                Label("USB 手机连接", systemImage: "cable.connector").font(.subheadline.weight(.semibold))
                Text(host.usbMessage + (host.usbDevice.map { " · " + $0 } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Button(host.usbDevice == nil ? "连接 USB 手机" : "断开 USB 手机") {
                    if host.usbDevice != nil { host.stopUSB() } else { Task { await host.startUSB(model) } }
                }.disabled(host.usbDevice == nil && (host.accessingKeychain || !model.backendMode.supportsUSBController))
                Divider()
                HStack {
                    if host.enabled || host.usbDevice != nil {
                        Button(reveal ? "隐藏配对码" : "显示配对码") { reveal.toggle() }
                    }
                    Button("撤销配对") { reveal = false; Task { await host.revoke() } }
                        .disabled(host.accessingKeychain)
                }
                if reveal && (host.enabled || host.usbDevice != nil) {
                    Text(host.code).font(.body.monospaced()).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
