import SwiftUI

/// 两个 iOS 应用共享同一读数视图，警告与两个字段始终来自同一条系统定位样本。
struct LocationSourceReadout: View {
    let sample: LocationObservation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sample.hasSoftwareSimulationWarning {
                Label(sample.predatesSubscription ? "警告：缓存样本为软件模拟定位" : "警告：此定位样本为软件模拟",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.red)
            }
            field("isSimulatedBySoftware", sample.isSimulatedBySoftware)
            field("isProducedByAccessory", sample.isProducedByAccessory)
        }
    }

    /// 保留系统未提供来源的情况，并允许复制字段名和值。
    private func field(_ name: String, _ value: Bool?) -> some View {
        Text(name + " = " + (value.map { $0 ? "true" : "false" } ?? "未知"))
            .font(.system(.footnote, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}
