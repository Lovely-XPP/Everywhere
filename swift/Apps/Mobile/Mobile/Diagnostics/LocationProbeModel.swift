import Combine
import CoreLocation
import Foundation

/// 独立诊断 App 的前台定位订阅状态；不代表外部设备命令的执行结果。
enum ProbeState: String {
    case idle = "未监听"
    case awaitingAuthorization = "等待定位授权"
    case receiving = "正在监听"
    case waitingForLocation = "暂时无法获取位置，正在等待新样本"
    case unavailable = "定位权限不可用"

    /// 已向系统订阅更新，等待定位期间仍可接收后续回调。
    var isListening: Bool { self == .receiving || self == .waitingForLocation }
}

/// 在主 actor 创建和管理 CLLocationManager，并在主线程的 Run Loop 接收回调。
/// 本类型只向 SwiftUI 公开当前状态和最新位置，不调用设备执行后端、不持久化轨迹。
/// CLLocationManagerDelegate 的旧式协议没有标注 actor；管理器由主 actor 创建，
/// Core Location 保证使用该线程的 Run Loop 回调，故在协议边界执行动态隔离检查。
@MainActor
final class LocationProbeModel: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var state = ProbeState.idle
    @Published private(set) var authorization = CLAuthorizationStatus.notDetermined
    @Published private(set) var accuracyAuthorization = CLAccuracyAuthorization.reducedAccuracy
    @Published private(set) var latestObservation: LocationObservation?
    @Published private(set) var subscriptionStart: Date?
    @Published private(set) var errorMessage: String?

    private let manager: CLLocationManager
    private var wantsUpdates = false

    /// 初始化前台定位订阅器；此时不请求授权，也不读取位置。
    /// - Parameter manager: 本轮及后续监听使用的管理器；默认使用系统定位服务。
    init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        refreshAuthorization()
        manager.delegate = self
    }

    /// 是否可以停止当前监听或取消待授权的监听请求。
    var canStop: Bool { wantsUpdates }

    /// 请求前台定位授权并启动监听；清空上一轮内存样本和错误。
    /// 重复启动无副作用；拒绝或受限制时仅更新诊断状态。
    func start() {
        guard !wantsUpdates else { return }
        latestObservation = nil
        subscriptionStart = nil
        errorMessage = nil
        wantsUpdates = true
        refreshAuthorization()
        reconcileSubscription(requestAuthorization: true)
    }

    /// 停止监听或取消待授权意图，保留最后一条样本供用户读数。
    /// 系统权限提示无法被此调用关闭；后续授权回调不会重新启动监听。
    func stop() {
        wantsUpdates = false
        manager.stopUpdatingLocation()
        state = .idle
    }

    /// 定位授权或精度授权发生变化时刷新状态，并仅在本轮请求尚未取消时启动监听。
    /// - Parameter manager: 发出回调的 Core Location 管理器。
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refreshAuthorization()
        if wantsUpdates {
            reconcileSubscription(requestAuthorization: false)
        }
    }

    /// 接收系统的位置批次，并覆盖最新的内存样本；未监听期间的回调不会写入。
    /// - Parameters:
    ///   - manager: 发出回调的 Core Location 管理器。
    ///   - locations: 系统返回的样本数组；空数组不更新观察记录。
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let receivedTime = Date()
        guard wantsUpdates, state.isListening, let subscriptionStart, let location = locations.last else {
            return
        }
        latestObservation = LocationObservation(
            location: location,
            receivedTime: receivedTime,
            subscriptionStart: subscriptionStart
        )
        if state == .waitingForLocation {
            guard location.timestamp >= subscriptionStart,
                  CLLocationCoordinate2DIsValid(location.coordinate),
                  location.horizontalAccuracy.isFinite, location.horizontalAccuracy >= 0 else { return }
            state = .receiving
        }
        errorMessage = nil
    }

    /// 记录系统报告的定位错误。临时不可用等错误不转为成功；权限被拒绝时停止。
    /// - Parameters:
    ///   - manager: 发出回调的 Core Location 管理器。
    ///   - error: 系统错误（例如 CLError.locationUnknown 或 CLError.denied）。
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard wantsUpdates else { return }
        if (error as? CLError)?.code == .locationUnknown, state.isListening {
            state = .waitingForLocation
            errorMessage = nil
            return
        }
        errorMessage = error.localizedDescription
        if (error as? CLError)?.code == .denied {
            refreshAuthorization()
            manager.stopUpdatingLocation()
            wantsUpdates = false
            state = .unavailable
        }
    }

    /// 刷新系统的授权与精度授权状态；不发起位置请求。
    private func refreshAuthorization() {
        authorization = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
    }

    /// 按授权状态推进本次监听。
    /// - Parameter requestAuthorization: 仅显式开始时允许显示系统授权提示。
    private func reconcileSubscription(requestAuthorization: Bool) {
        switch authorization {
        case .notDetermined:
            state = .awaitingAuthorization
            if requestAuthorization {
                manager.requestWhenInUseAuthorization()
            }
        case .authorizedWhenInUse, .authorizedAlways:
            guard !state.isListening else { return }
            subscriptionStart = Date()
            state = .receiving
            manager.startUpdatingLocation()
        case .denied, .restricted:
            manager.stopUpdatingLocation()
            wantsUpdates = false
            state = .unavailable
        @unknown default:
            manager.stopUpdatingLocation()
            wantsUpdates = false
            state = .unavailable
        }
    }
}
