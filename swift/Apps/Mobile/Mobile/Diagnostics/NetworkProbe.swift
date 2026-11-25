import Combine
import Foundation
import Network
import class NetworkExtension.NEHotspotNetwork

/// 本机默认网络路径和当前接入点的独立观测，仅在内存比较 BSSID，不查询地理位置。
@MainActor
final class NetworkProbe: ObservableObject {
    struct Sample {
        let date: Date
        let route: String
        let comparison: String
    }

    @Published private(set) var route = "等待读取"
    @Published private(set) var ready = false
    @Published private(set) var reading = false
    @Published private(set) var last: Sample?
    private var monitor: NWPathMonitor?
    private var path: NWPath?
    private var baseline: String?
    private var request: Task<Void, Never>?

    /// 开始跟踪默认路径。仅接受现用监视器的回调。
    func start() {
        guard monitor == nil else { return }
        let observer = NWPathMonitor()
        monitor = observer
        observer.pathUpdateHandler = { [weak self, weak observer] newPath in
            Task { @MainActor in
                guard let self, let observer, self.monitor === observer else { return }
                self.request?.cancel()
                self.reading = false
                self.path = newPath
                self.route = Self.describe(newPath)
                self.ready = true
            }
        }
        observer.start(queue: DispatchQueue(label: "LocationProbe.network-path"))
    }

    /// 暂停监视并丢弃未完成读数。保留已完成样本以便切换 App 后作对照。
    func stop() {
        request?.cancel()
        monitor?.cancel()
        monitor = nil
        path = nil
        ready = false
        reading = false
        route = "等待读取"
    }

    /// 记录当前路径；在真机 Wi-Fi 路径上以首个可用接入点作为本次运行的基线。
    func capture() {
        guard let path, !reading else { return }
        let sampledRoute = route
        guard path.status == .satisfied, path.usesInterfaceType(.wifi) else {
            last = Sample(date: Date(), route: sampledRoute, comparison: "当前路径未使用 Wi-Fi")
            return
        }
        #if targetEnvironment(simulator)
        last = Sample(date: Date(), route: sampledRoute, comparison: "模拟器无法验证实体接入点")
        #else
        reading = true
        request = Task {
            let network = await NEHotspotNetwork.fetchCurrent()
            guard !Task.isCancelled else { return }
            reading = false
            var comparison = "未取得接入点标识"
            if let id = network?.bssid.lowercased(), !id.isEmpty, id != "00:00:00:00:00:00" {
                if let baseline {
                    comparison = baseline == id ? "与首次取样相同" : "与首次取样不同"
                } else {
                    baseline = id
                    comparison = "已记录首次可用接入点"
                }
            }
            last = Sample(date: Date(), route: sampledRoute, comparison: comparison)
        }
        #endif
    }

    /// 列出默认可用网络路径用到的接口，可同时包含多个接口。
    private static func describe(_ path: NWPath) -> String {
        guard path.status == .satisfied else {
            return path.status == .requiresConnection ? "等待连接" : "无可用路径"
        }
        let types: [(NWInterface.InterfaceType, String)] = [
            (.wifi, "Wi-Fi"), (.cellular, "蜂窝网络"), (.wiredEthernet, "以太网"),
            (.loopback, "本机回环"), (.other, "其他")
        ]
        let names = types.compactMap { path.usesInterfaceType($0.0) ? $0.1 : nil }
        return names.isEmpty ? "接口未知" : names.joined(separator: "、")
    }
}
