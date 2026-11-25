import CoreBluetooth
@preconcurrency import IOBluetooth
import SwiftUI

/// 发现经典蓝牙设备，停止搜索后将用户选择的地址交给连接会话。
@MainActor
private final class IPhonePairing: NSObject, ObservableObject, IOBluetoothDeviceInquiryDelegate {
    @Published private(set) var devices: [String: String] = [:]
    @Published private(set) var message = "准备搜索附近设备…"
    @Published private(set) var searching = false
    @Published private(set) var handingOff = false

    var onSelect: ((String, String) -> Void)?
    private var inquiry: IOBluetoothDeviceInquiry?
    private var selected: String?
    private var timeout: Task<Void, Never>?

    /// 使用系统的异步搜索，在主运行循环接收结果。即使系统没有回调也会结束等待。
    func search() {
        guard !searching, !handingOff else { return }
        devices.removeAll()
        switch CBManager.authorization {
        case .denied, .restricted:
            message = "蓝牙访问受限。请在「系统设置 → 隐私与安全性 → 蓝牙」中允许 Everywhere 访问蓝牙。"
            return
        default: break
        }
        guard let scan = IOBluetoothDeviceInquiry(delegate: self) else {
            message = "无法启动蓝牙搜索，请在系统设置中检查 Mac 蓝牙。"
            return
        }
        inquiry = scan
        scan.inquiryLength = 10
        scan.updateNewDeviceNames = true
        searching = true
        message = "正在搜索附近的经典蓝牙设备…"
        limitWait(seconds: 30, message: "蓝牙搜索超时。请检查两端蓝牙，或从列表中选择已发现的设备。")
        let result = scan.start()
        if result != kIOReturnSuccess { fail("无法开始搜索。请检查 Mac 蓝牙开关与访问权限", result) }
    }

    /// 仅配对用户点选的地址；经典蓝牙查询完成后才开始建立配对连接。
    func select(_ address: String) {
        guard !handingOff, devices[address] != nil else { return }
        handingOff = true
        selected = address
        message = "正在准备与\(devices[address] ?? "所选设备")配对…"
        limitWait(seconds: 10, message: "未能结束设备搜索，请重新选择 iPhone。")
        if let inquiry {
            let result = inquiry.stop()
            if result != kIOReturnSuccess && self.inquiry === inquiry { fail("无法结束蓝牙搜索，请重新搜索", result) }
        } else {
            connect(address)
        }
    }

    private func connect(_ address: String) {
        let name = devices[address] ?? "iPhone"
        cancel()
        onSelect?(address, name)
    }

    private func record(_ device: IOBluetoothDevice) {
        guard let address = device.addressString else { return }
        devices[address] = device.name ?? "未命名设备"
    }

    nonisolated func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        DispatchQueue.main.async { [self] in
            guard sender === inquiry, let device else { return }
            record(device)
        }
    }

    nonisolated func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!, devicesRemaining: UInt32) {
        deviceInquiryDeviceFound(sender, device: device)
    }

    nonisolated func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        DispatchQueue.main.async { [self] in
            guard let sender, sender === inquiry else { return }
            sender.delegate = nil
            inquiry = nil
            searching = false
            if let selected, error == kIOReturnSuccess || aborted { connect(selected); return }
            timeout?.cancel()
            if error != kIOReturnSuccess { fail("蓝牙搜索失败，请检查蓝牙设置", error); return }
            message = devices.isEmpty ? "没有发现设备。请让 iPhone 停留在「设置 → 蓝牙」，然后重新搜索。" : "选择要配对的 iPhone。"
        }
    }

    private func fail(_ detail: String, _ code: IOReturn) {
        cancel()
        message = detail + String(format: "（0x%08X）。", UInt32(bitPattern: code))
    }

    private func limitWait(seconds: Int, message: String) {
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.cancel()
            self?.message = message
        }
    }

    /// 先解除委托，再停止原生操作，防止迟到的回调更新下一次搜索的界面。
    func cancel() {
        timeout?.cancel()
        timeout = nil
        inquiry?.delegate = nil
        _ = inquiry?.stop()
        inquiry = nil
        selected = nil
        searching = false
        handingOff = false
    }
}

/// 在设备检查器内显示经典蓝牙搜索状态和可连接设备。
struct IPhonePairingPanel: View {
    @StateObject private var model = IPhonePairing()
    let onClose: () -> Void
    let onConnect: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("解锁 iPhone，打开「设置 → 蓝牙」并停留在该页面。")
                .font(.callout)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if model.searching || model.handingOff { ProgressView().controlSize(.small) }
                Text(model.message)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pairingStatus")
            }
            if !model.devices.isEmpty {
                VStack(spacing: 4) {
                    ForEach(model.devices.keys.sorted(), id: \.self) { address in
                        BluetoothActionCard(title: model.devices[address] ?? address,
                                            symbol: "iphone", detail: address) {
                            model.select(address)
                        }.disabled(model.handingOff)
                    }
                }
            }
            HStack {
                Button("重新搜索") { model.search() }.disabled(model.searching || model.handingOff)
                Spacer()
                Button(model.handingOff ? "取消连接" : "返回") {
                    model.cancel()
                    onClose()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { model.onSelect = onConnect; model.search() }
        .onDisappear { model.cancel() }
    }
}
