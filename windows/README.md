# Everywhere Windows 控制台

源码位于项目根目录的 `windows/`，共享设备后端位于 `swift/Host/`。Windows 使用 PySide6 的 Qt Widgets 界面、异步 Python 设备会话和两个原生 C++ 蓝牙桥。

## Windows x64 构建

构建机使用 Windows 11 x64、CPython 3.13 x64（含 py launcher 和 TLS-PSK）、Visual Studio C++ x64 Build Tools、Windows 11 SDK 与桌面 C++/WinRT 头文件。首次构建需要下载 Python 依赖。项目的 `swift/Host/ModernBackend/portable_location.py` 支持 `session(args, consumer=None)`，`swift/Host/IAP2Client/src/accessory_location/cli.py` 含 `pending_input()`。打包脚本检查 Python 依赖，并在成品自检中验证定位服务接口和版本。

在项目根目录的 Windows PowerShell 中运行：

```powershell
.\package-windows.ps1
```

脚本编译 RFCOMM 和 GATT 辅助程序，冻结 Qt 客户端和已有设备后端，运行协议回归、辅助进程自检以及打包后的 Qt 启动检查。通过后在 `Build/Exports/` 生成带时间戳的 x64 ZIP。解压完整目录后打开 `Everywhere.exe`，运行端使用随包的 Qt 和 Python。USB 设备识别依赖可用的 Apple 设备服务。

Windows 包默认包含 `asset/mfi/certificate.p7b` 和可读取的原始签名私钥 `asset/mfi/identity.pk8`，打包时核验证书公钥与私钥是否匹配。通过 `.\package-windows.ps1 -EmbedMfiKey:$false` 可生成仅含证书的包，此时可在运行端使用 `%LOCALAPPDATA%\Everywhere\MFi\identity.pk8`。环境变量 `EVERYWHERE_MFI_KEY` 可指定其他私钥路径。也支持通过 `EVERYWHERE_AUTH_PROVIDER` 指定现有项目兼容的外部认证程序。iOS 分发材料沿用原 Apple 打包流程。

## 使用

- **软件模拟**。用数据线接入并解锁手机，刷新列表，点击目标设备和“信任设备并启用 Wi-Fi”。无线连接需要两端在同一局域网。按 iOS 要求确认信任、开启开发者模式及准备开发镜像。同一 UDID 合并展示可用链路，同名手机保留独立条目并显示设备标识后八位。在「仅 Wi-Fi」下也可输入手机 IP，使用本机已有配对记录验证。后续连接会再次核对 UDID；活动链路断开后须先恢复结果未知的会话。设备侧行为沿用固定版本的开发定位后端。早期 iOS 17.0–17.3 的 Windows 特殊隧道配置仍需单独验证。
- **地图**。点击地图或手输 WGS 84 经纬度，各模式共用底部的“发送地图选点”。目标连接就绪并选择有效坐标后，点击发送并确认“我已知晓”才会提交。支持缩放、搜索、最近地点、收藏以及自定义带署名的 HTTPS XYZ 图层。自定义图层可选择 GCJ-02；内部的设备坐标和收藏始终使用 WGS 84。默认地图和地点搜索分别访问 OpenStreetMap 和 Nominatim，离线时可以使用经纬度输入和本地收藏。
- **经典蓝牙 iAP2**。从“已有iPhone连接”选择目标，或点“连接新 iPhone”搜索并选择附近的设备。应用通过 Windows 系统认证流程打开 RFCOMM，随后完成 iAP2 配件识别和 MFi 认证。初次连接和重连均等候用户确认新选点。可切换半径 5 米的发送抖动。会话页显示位置订阅、链路回执与发送坐标。
- **手机 App 蓝牙标记**。在“电脑扫描手机”和“手机扫描电脑”之间选择对应方向。打开 iPhone 的 Everywhere 蓝牙接收页并输入其六位码。电脑扫描手机时，先连接接收服务。手机扫描电脑时，先点“开启电脑蓝牙广播”，待手机订阅后刷新并选择目标。反向链路按设备和消息编号核对手机回执。手机当前版本中“Mac”的文案对应此处的桌面主机。
- **手机遥控**。新手机先选择已接线的 USB 目标，开启 USB 遥控并在手机输入配对码，取得本机绑定。之后可开启网络遥控，使用 Bonjour 或手动地址、端口连接。主机在 Windows 凭据存储中保存配对材料，可在遥控菜单撤销。公网访问还需要用户自己的可达网络入口。
- **清除与退出**。退出模式时，客户端会尝试清除本次软件模拟。失联或结果未知时需重连同一设备并显式恢复。iAP2 停止发送和普通 BLE 的清除标记分别有独立入口。

## 验证范围

Windows 目标使用 PySide6 / Qt 6。控制台测试覆盖 Qt 选点、发送确认、同名设备、USB/Wi-Fi 换线与断线恢复、iAP2 认证与重连、临时测试身份签名和回环 TLS-PSK，运行环境为 macOS 与 Qt 6。Windows 打包脚本另执行两个原生蓝牙桥的无设备自检，并从冻结的 Qt 应用加载 WinRT 蓝牙后端。Windows x64 原生编译、系统蓝牙栈、USB 驱动和真实 iPhone 的位置采纳仍需在对应环境验收。

建议首先用同一部已在 Mac 版正常工作的 iPhone，关闭抖动后依次记录真实位置 A、选点 B、换点 C、停止后恢复 A。同步观察独立 Core Location 新样本、样本时间和来源字段。新设备另测首次 USB 信任与拔线后的 Wi-Fi 识别。Windows 分发包还应在没有 Qt SDK、Python 和 Xcode 的第二台电脑验收。
