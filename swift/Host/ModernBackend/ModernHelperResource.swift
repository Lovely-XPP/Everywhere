import Foundation

/// 定位随桌面程序交付的开发工具适配脚本；Python 环境由用户在主机上选择。
public enum ModernHelperResource {
    /// 脚本缺失时返回 nil，让控制台在启动子进程前报告打包问题。
    public static var scriptURL: URL? {
        Bundle.module.url(forResource: "modern_backend", withExtension: "py")
    }
}
