import CoreLocation
import Foundation
import SwiftUI

/// 独立、只读的 iOS / iPadOS 真机定位诊断入口。
@main
@MainActor
struct LocationProbeApp: App {
    @StateObject private var model = LocationProbeModel()

    @StateObject private var network = NetworkProbe()

    var body: some Scene {
        WindowGroup {
            LocationProbeView(model: model, network: network)
        }
    }
}
