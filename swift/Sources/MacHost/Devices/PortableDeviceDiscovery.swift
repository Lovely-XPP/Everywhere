import DeviceBackend
import Foundation
import IOKit

/// 系统连接记录。设备名仅在系统注册表或已配对的服务报告时提供。
struct PortableDevice: Decodable, Sendable {
    let id: String
    let name: String?
    let network: Bool

    /// 新设备的 24 位序列号在 USB 注册表里有时不带 UDID 分隔符。
    var key: String {
        let value = id.replacingOccurrences(of: "-", with: "").lowercased()
        if value.count == 24, value.allSatisfy(\.isHexDigit) {
            return String(value.prefix(8)) + "-" + String(value.dropFirst(8))
        }
        return id.lowercased()
    }

    /// usbmuxd 负责区分 USB 与网络连接，IOKit 补充插线后仍在等待信任的设备。
    static func attached() async throws -> [Self] {
        let physical = await Task.detached(priority: .utility) { registryDevices() }.value
        do {
            let data = try await USBRemoteConnection.deviceList()
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
            guard let records = (plist as? [String: Any])?["DeviceList"] as? [[String: Any]] else {
                throw RemoteDeviceListingError()
            }
            let mux: [Self] = records.compactMap { row in
                guard let props = row["Properties"] as? [String: Any], let serial = props["SerialNumber"] as? String,
                      !serial.isEmpty, let type = props["ConnectionType"] as? String, ["USB", "Network"].contains(type)
                else { return nil }
                return Self(id: serial, name: nil, network: type == "Network")
            }
            return mux + physical
        } catch {
            if !physical.isEmpty { return physical }
            throw error
        }
    }

    private struct RemoteDeviceListingError: LocalizedError {
        var errorDescription: String? { "系统 USB 服务未返回设备列表。" }
    }

    private static func registryDevices() -> [Self] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var result: [Self] = []
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }
            func property(_ key: String) -> AnyObject? {
                IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard (property("idVendor") as? NSNumber)?.intValue == 0x05ac,
                  let name = property("USB Product Name") as? String, name.hasPrefix("iPhone") || name.hasPrefix("iPad"),
                  let serial = property("USB Serial Number") as? String else { continue }
            let raw = serial.replacingOccurrences(of: "-", with: "")
            guard [24, 40].contains(raw.count), raw.allSatisfy(\.isHexDigit) else { continue }
            result.append(Self(id: serial, name: name, network: false))
        }
        return result
    }
}
