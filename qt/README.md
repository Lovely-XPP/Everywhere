# Everywhere 0.2.2 Python / Qt 桌面版

`qt/` 是三个平台共用的 Python 源码目录。地图、USB/Wi-Fi 定位会话、iAP2 协议和手机遥控共用一套实现。经典蓝牙与 BLE 使用各平台的系统后端。

## 各平台打包

在目标系统的项目根目录执行对应命令。各包包含 Qt 和 Python，默认输出到 `Build/Exports/`。构建需要带 TLS-PSK 的 CPython 3.13 及项目依赖，首次安装依赖需要联网。

| 平台 | 打包命令 | 产物和启动方式 |
| --- | --- | --- |
| macOS 14+ | `./package-python-macos.sh` | 与构建机架构对应的 ZIP，解压双击 `EverywhereQt.app` |
| Windows 11 x64 | `.\package-windows.ps1` | 双击生成的 x64 单文件 EXE |
| Linux 桌面 | `./package-python-linux.sh` | 给单文件程序添加执行权限（`chmod +x 文件名`），运行 `./文件名` |

**macOS**。构建机需要含 macOS SDK、clang 和 Swift 5.9 或更新版本的 Apple 开发工具。经典蓝牙通过 IOBluetooth 连接，BLE 双向传输复用原 Swift 版的 CoreBluetooth 后端。运行端按系统提示允许蓝牙与本地网络。默认产物在本地作 ad-hoc 签名。原生 Swift macOS 和 iPhone/iPad 使用原入口 `./package.sh`。

**Linux**。构建机需要 `python3.13-venv` 或发行版等价组件、`binutils`，以及所选 Python 依赖在当前架构上的 wheel 或相应编译工具。建议在计划支持的最旧 glibc 发行版上构建。运行端需要图形桌面及 Qt 的 X11/XCB 或 Wayland 运行库、系统 D-Bus 和 usbmuxd。蓝牙模式还需要已启动的 BlueZ、`bluetoothctl`、支持经典蓝牙的适配器，以及能通过 `sdptool browse --xml` 查询 SDP 的 BlueZ 工具。创建新配对需要桌面蓝牙配对代理。手机扫描电脑还需要控制器支持 BLE 外设广播，BlueZ 提供按设备的 `AcquireNotify`。手机遥控配对材料保存到桌面 Secret Service。打包脚本自检不会代替驱动及实机验收。

**证书和输出**。三个脚本默认把 `asset/mfi/certificate.p7b` 和可读取的原始私钥 `asset/mfi/identity.pk8` 一起放入包，并在归档前核验匹配。macOS/Linux 可加 `--without-key`，Windows 使用 `-EmbedMfiKey:$false`。仅含证书时，可用 `EVERYWHERE_MFI_KEY` 指定私钥，或放在以下位置。

| 平台 | 用户私钥默认位置 |
| --- | --- |
| macOS | `~/Library/Application Support/Everywhere/MFi/identity.pk8` |
| Windows | `%LOCALAPPDATA%\Everywhere\MFi\identity.pk8` |
| Linux | `${XDG_DATA_HOME:-~/.local/share}/Everywhere/MFi/identity.pk8` |

macOS/Linux 还支持 `--output-dir 目录`、`--prepared-python 已装完整依赖的解释器路径`。从源码运行时，先用对应脚本加 `--helpers-only` 准备辅助程序，再用同一 Python 环境运行 `python qt/app.py`。Windows 打包成功后也会准备源码运行所需的辅助程序。

## Windows x64 构建

构建机使用 Windows 11 x64、CPython 3.13 x64（含 py launcher 和 TLS-PSK）、Visual Studio C++ x64 Build Tools、Windows 11 SDK 与桌面 C++/WinRT 头文件。首次构建需要下载 Python 依赖。项目的 `swift/Host/ModernBackend/portable_location.py` 支持 `session(args, consumer=None)`，`swift/Host/IAP2Client/src/accessory_location/cli.py` 含 `pending_input()`。打包脚本检查 Python 依赖，并在成品自检中验证定位服务接口和版本。

在项目根目录的 Windows PowerShell 中运行：

```powershell
.\package-windows.ps1
```

脚本编译 RFCOMM 和 GATT 辅助程序，冻结 Qt 客户端和已有设备后端，运行协议回归、辅助进程自检以及打包后的 Qt 启动检查。通过后在 `Build/Exports/` 生成 `Everywhere-<版本>-windows-x64.exe`。Windows 和 Linux 单文件程序启动时会将 Qt、Python 和辅助程序释放到临时目录。Linux 的临时目录需要允许执行程序。USB 设备识别依赖可用的 Apple 设备服务。

可通过 `EVERYWHERE_AUTH_PROVIDER` 指定兼容的外部认证程序。

## 使用

- **软件模拟**。用数据线接入并解锁手机，刷新列表，点击目标设备和“信任设备并启用 Wi-Fi”。无线连接需要两端在同一局域网。按 iOS 要求确认信任、开启开发者模式及准备开发镜像。同一 UDID 合并展示可用链路，同名手机保留独立条目并显示设备标识后八位。在「仅 Wi-Fi」下也可输入手机 IP，使用本机已有配对记录验证。后续连接会再次核对 UDID；活动链路断开后须先恢复结果未知的会话。设备侧行为沿用固定版本的开发定位后端。早期 iOS 17.0–17.3 的 Windows 特殊隧道配置仍需单独验证。
- **地图**。点击地图或手输 WGS 84 经纬度，各模式共用底部的“发送地图选点”。目标连接就绪并选择有效坐标后，点击发送并确认“我已知晓”才会提交。支持缩放、搜索、最近地点、收藏以及自定义带署名的 HTTPS XYZ 图层。可选择 WGS 84 或 GCJ-02。Qt 地图组件对两项使用相同的 WGS 84 经纬度，自定义 XYZ 图层也应与该基准对齐。选点、收藏和设备坐标均使用 WGS 84。默认地图和地点搜索分别访问 OpenStreetMap 和 Nominatim，离线时可以使用经纬度输入和本地收藏。
- **经典蓝牙 iAP2**。从“已有iPhone连接”选择目标，或点“连接新 iPhone”搜索并选择附近的设备。应用通过本机系统蓝牙流程打开 RFCOMM，随后完成 iAP2 配件识别和 MFi 认证。初次连接和重连均等候用户确认新选点。可切换半径 5 米的发送抖动。会话页显示位置订阅、链路回执与发送坐标。
- **手机 App 蓝牙标记**。在“电脑扫描手机”和“手机扫描电脑”之间选择对应方向。打开 iPhone 的 Everywhere 蓝牙接收页并输入其六位码。电脑扫描手机时，先连接接收服务。手机扫描电脑时，先点“开启电脑蓝牙广播”，待手机订阅后刷新并选择目标。反向链路按设备和消息编号核对手机回执。手机当前版本中“Mac”的文案对应此处的桌面主机。
- **手机遥控**。新手机先选择已接线的 USB 目标，开启 USB 遥控并在手机输入配对码，取得本机绑定。之后可开启网络遥控，使用 Bonjour 或手动地址、端口连接。主机在系统凭据存储中保存配对材料，可在遥控菜单撤销。公网访问还需要用户自己的可达网络入口。
- **清除与退出**。退出模式时，客户端会尝试清除本次软件模拟。失联或结果未知时需重连同一设备并显式恢复。iAP2 发送选点后，点「恢复真实定位」并确认以结束配件位置输出；普通 BLE 模式使用「清除手机 App 标记」。

## 验证范围

macOS arm64 已构建 Qt 分发包，并验证解压后的代码签名、Qt 离屏启动、包内插件和配件身份匹配。共用回归用例覆盖地图发送与恢复、USB 目标绑定、切换链路、蓝牙断线与遥控协议。Linux 的 D-Bus 多手机隔离用例会在 Linux 构建环境中运行。Windows 和 Linux 的原生构建、各系统蓝牙/USB 驱动以及真实 iPhone 的位置采纳均需在对应环境验收。

建议首先用同一部已在 Mac 版正常工作的 iPhone，关闭抖动后依次记录真实位置 A、选点 B、换点 C、停止后恢复 A。同步观察独立 Core Location 新样本、样本时间和来源字段。新设备另测首次 USB 信任与拔线后的 Wi-Fi 识别。Windows 分发包还应在没有 Qt SDK、Python 和 Xcode 的第二台电脑验收。

## Android 配件执行端（实验）

Android 手机运行前台 Qt 控制台，在系统蓝牙设置中配对 iPhone，返回控制台允许访问附近设备并刷新。在列表中选择目标手机；若本机地址留空，从 Android 系统的关于手机或状态页填写安卓本机的经典蓝牙地址。连接后等待配件识别和认证通过，在地图上选点并确认发送。结束会话会断开配件连接，请在 iPhone 的独立定位诊断中检查恢复结果。前台进程退出或蓝牙断开后重新连接需要重新选定发送操作。

Android 分发构建使用 Qt for Python 6.8.3 和 JDK 17。脚本从 `avdmanager list target` 能识别的已安装平台中选择最高稳定整级平台（API 34 起）和完整的 Build Tools（35.0.0 起），并复用 NDK r27c 或 r26b。缺少合适组件时才请求安装。可用 `EVERYWHERE_ANDROID_API`、`EVERYWHERE_ANDROID_BUILD_TOOLS` 和 `ANDROID_NDK_ROOT` 显式选择版本。安装下限为 **Android 9.0（API 28）及 arm64-v8a**。Android 9–11 通过普通蓝牙权限读取系统已配对设备，Android 12 起会申请附近设备权限。两部手机均按系统正常配对操作，Android 端无需 root 或开启模拟位置权限。

在 macOS 或 Linux 项目根目录运行：

```sh
./setup-android.sh --release
```

脚本在 `Build/AndroidEnv/` 复用或创建 Python 虚拟环境，准备 SDK、NDK、Gradle 缓存及官方 arm64 wheels。宿主 Python 依赖优先使用已安装版本和 `host-wheels/` 本地包缓存，仅缺少依赖时联网下载；官方 Android wheels 保存在 `wheels/`，打包时首次下载的 python-for-android 源码保存在 `downloads/` 并在后续构建中复用。首次构建需要联网；SDK 许可按安装程序提示处理。可通过 `JAVA_HOME` 选择 JDK 17，通过 `ANDROID_HOST_PYTHON` 选择 Python 3.10/3.11，通过 `ANDROID_SDK_ROOT` 或 `ANDROID_HOME` 指定 SDK。未指定时，脚本查找项目和 Android Studio 的默认 SDK 目录。仅运行 `./setup-android.sh` 可单独准备环境。

python-for-android 下载的 CPython、OpenSSL、SQLite 等 recipe 源码包及下载完成标记保存在 `Build/AndroidEnv/packages/`，即使构建失败也会保留已成功下载的文件。默认将原生编译产物及 Android distribution 保存到 `Build/AndroidEnv/build/<缓存键>/`；如果项目路径包含中文、其他非 ASCII 字符或空白，则使用用户缓存目录（macOS 为 `~/Library/Caches/Everywhere/android/`，Linux 为 `$XDG_CACHE_HOME/everywhere/android/` 或 `~/.cache/everywhere/android/`），按项目和工具链隔离。也可通过 `EVERYWHERE_ANDROID_BUILD_CACHE` 指定纯 ASCII、无空白的缓存根目录。工具链、依赖内容或构建配置变化时自动使用新的缓存目录；修改业务 Python 代码后仍会重新组装 APK 并执行签名检查。缓存仅供本机使用，不应上传或共享完整目录（其中可能包含应用打包资源）。需要强制重新编译时运行 `./setup-android.sh --release --clean`，保留已下载的依赖。macOS 需要通过 `brew install make` 安装新版 GNU Make，打包脚本自动选用 `gmake`，避免系统自带 Make 3.81 与新版 Automake 不兼容。

原生编译规则使用独立的 `NATIVE_BUILD_REVISION` 缓存版本；仅修改业务代码、资源、APK 组装或签名配置不会改变原生编译缓存键。Cargo 下载缓存默认位于 `Build/AndroidEnv/cargo/`，可通过 `EVERYWHERE_ANDROID_CARGO_CACHE` 单独指定。

发布包默认使用本机 `asset/android-signing/release.p12`（别名 `everywhere`）和同目录的 `password` 文件。迁移构建机时应安全备份并复用发布身份。也可使用 `EVERYWHERE_ANDROID_KEYSTORE`、`EVERYWHERE_ANDROID_KEY_ALIAS` 和 `EVERYWHERE_ANDROID_PASSWORD_FILE` 指定现有身份。它们用于 Android 安装包签名。用于 iPhone 配件认证的 `asset/mfi/` 身份会随包分发；持有 APK 的人可以提取配件私钥。

发布构建检查最终 APK 的最低系统版本、arm64 原生库、调试标志和签名，通过后输出到 `Build/Android/Everywhere-0.2.2-arm64-release.apk`。可用已安装工具链执行 `python package-android.py --help` 查看独立打包参数。仍需通过 Android 真机和 iPhone 核对识别、认证、连续设点和恢复。
