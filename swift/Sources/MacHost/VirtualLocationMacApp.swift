import SwiftUI

/// Mac 控制台的程序入口。单一窗口共享同一模型，避免为同一台设备重复建立会话。
@main
@MainActor
struct VirtualLocationMacApp: App {
    @StateObject private var model = MacConsoleModel()

    /// 创建唯一控制台窗口，不自动向真机发出定位指令。
    var body: some Scene {
        Window("Everywhere", id: "mac-console") {
            MacConsoleView(model: model)
        }
        .defaultSize(width: 1080, height: 740)
    }
}
