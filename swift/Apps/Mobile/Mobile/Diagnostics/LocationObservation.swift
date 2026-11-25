import CoreLocation
import Foundation

/// 一次独立的 Core Location 样本，只在内存中保留最新一条。
struct LocationObservation {
    /// CLLocation 返回的坐标；单位为度，纬度范围 [-90, 90]，经度范围 [-180, 180]。
    let coordinate: CLLocationCoordinate2D

    /// CLLocation 返回的样本生成时间（绝对时间，不是接收时间）。
    let sampleTime: Date

    /// 诊断 App 所在设备接到定位回调的时间。
    let receivedTime: Date

    /// 水平精度，单位为米；负值或非有限值表示无有效精度。
    let horizontalAccuracy: CLLocationAccuracy

    /// Core Location 是否标记为软件模拟；nil 表示系统未提供来源信息。
    let isSimulatedBySoftware: Bool?

    /// Core Location 是否标记为外接配件提供；nil 表示系统未提供来源信息。
    let isProducedByAccessory: Bool?

    /// 仅由系统的软件模拟字段触发；配件来源独立展示。
    var hasSoftwareSimulationWarning: Bool { isSimulatedBySoftware == true }

    /// 样本时间是否早于本次实际监听的启动时间。
    let predatesSubscription: Bool

    /// 将单条系统样本转换为独立观察记录。
    /// - Parameters:
    ///   - location: 系统定位回调中的位置，允许包含无效坐标或精度字段。
    ///   - receivedTime: 回调接收时间；批次内的样本可共用此时间。
    ///   - subscriptionStart: 本次调用 startUpdatingLocation 的时间。
    init(location: CLLocation, receivedTime: Date, subscriptionStart: Date) {
        coordinate = location.coordinate
        sampleTime = location.timestamp
        self.receivedTime = receivedTime
        horizontalAccuracy = location.horizontalAccuracy
        isSimulatedBySoftware = location.sourceInformation?.isSimulatedBySoftware
        isProducedByAccessory = location.sourceInformation?.isProducedByAccessory
        predatesSubscription = location.timestamp < subscriptionStart
    }

    /// 接收时间减去样本时间，单位为秒；负值表示设备时钟需要核对。
    var sampleAgeAtReceipt: TimeInterval {
        receivedTime.timeIntervalSince(sampleTime)
    }
}
