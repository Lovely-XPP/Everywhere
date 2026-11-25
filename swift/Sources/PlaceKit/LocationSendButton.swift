import SwiftUI

/// 两端共用的发送入口。点击时保存本次选点操作，取消或关闭提示时丢弃。
@MainActor
public struct LocationSendButton<Label: View>: View {
    private struct PendingSend {
        let execute: () -> Void
    }

    private let prepare: () -> (() -> Void)?
    private let recoveryAction: String
    private let label: Label
    @State private var pending: PendingSend?

    /// prepare 只捕获目标、会话和坐标；返回的操作仅在用户点击「我已知晓」后执行。
    public init(recoveryAction: String, prepare: @escaping () -> (() -> Void)?, @ViewBuilder label: () -> Label) {
        self.recoveryAction = recoveryAction
        self.prepare = prepare
        self.label = label()
    }

    public var body: some View {
        Button {
            guard pending == nil, let execute = prepare() else { return }
            pending = PendingSend(execute: execute)
        } label: { label }
        .alert("发送选点前请确认", isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        ), presenting: pending) { request in
            Button("我已知晓") { request.execute() }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("发送后，请在目标设备打开「设置 → 隐私与安全性 → 定位服务」，关闭再打开「定位服务」，使新位置生效。\n\n如需恢复，请先点击「\(recoveryAction)」，再关闭并重新打开「定位服务」。如果仍未生效，请重启设备。")
        }
    }
}
