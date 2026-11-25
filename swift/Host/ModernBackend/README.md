# P0 · 现代 USB 真机后端

这是一个仅用于经设备所有者许可的开发定位模拟工具，供 Mac 主机调用或由用户独立完成 P0 验收。它把 `pymobiledevice3` 的官方 Python 开发服务接口封装成一个 JSONL 辅助进程，而不是 App 内部伪造地图坐标。保持同一 DVT 会话完成设点、更换地点、清除。

**候选环境（尚未实测）**：macOS、iOS/iPadOS 17.4 及更新版本、已信任 Mac 的 USB 真机。iOS 17.0–17.3 暂不进入本实现范围；不自动回退到其他网络隧道、不自动配对、不申请提升权限、不修改开发者模式。iPadOS 各版本、Wi-Fi 连接以及独立移动端执行都需单独验收。不要与持有同一设备开发定位会话的 Xcode/其他工具同时操作。

## 准备与手工使用

1. 自行准备 Python 3.11 或 3.12。在项目根目录运行以下命令安装固定版本到独立虚拟环境；没有全局安装、提权或设备操作的要求。虚拟环境放在项目外。

   ```sh
   python3 -m venv "$HOME/.venvs/virtual-location-p0"
   "$HOME/.venvs/virtual-location-p0/bin/python" -m pip install -r swift/Host/ModernBackend/requirements.txt
   ```

2. 用数据线连接设备、解锁，由用户在真机上确认信任此 Mac；确保用户已通过 Apple 提供的正常流程启用开发者模式。如果开发服务尚未就绪，使用 Xcode 的 Devices and Simulators / Device Hub 完成设备准备；本程序不代为安装开发者镜像或更改系统设置。

3. 查看 USB 设备列表，人工选定设备并记录 UDID。以下上游命令仅作为手工发现入口，不应将未明确选定的设备交给辅助进程：

   ```sh
   "$HOME/.venvs/virtual-location-p0/bin/pymobiledevice3" usbmux list
   ```

4. 先用独立 LocationProbe 记录真实位置 A 的样本，再启动辅助进程；将参数替换为实际选定真机的 UDID：

   ```sh
   "$HOME/.venvs/virtual-location-p0/bin/python" swift/Host/ModernBackend/modern_backend.py --udid '实际UDID'
   ```

   等待标准输出出现 `event: ready`。它表示已核实设备身份、USB 配对和候选系统范围，并已建立 DVT 位置模拟通道，不表示位置已经改变。

5. 在该进程的终端（或宿主 stdin 管道）逐行输入下列 JSON。先发第一行并等待 receipt，观察 Probe 的新样本；第二行更换位置，再次观察；第三行清除并独立确认真实位置。如果已完成恢复再退出。

   ```jsonl
   {"requestID":"point-b","command":"set","latitude":37.3349,"longitude":-122.0090}
   {"requestID":"point-c","command":"set","latitude":37.8080,"longitude":-122.4177}
   {"requestID":"clear-1","command":"clear"}
   {"requestID":"quit-1","command":"quit"}
   ```

   示例点仅作为 P0 测试坐标。务必根据实际基线选择明显分离的 B、C。Probe 观察须区分请求前的旧样本、请求后的新样本和水平精度。

## 主机进程通信契约

- 启动参数 `--udid` 必填；一进程仅对应一台真机，启动后不允许更换 UDID。在 USB 列表中唯一匹配该标识后才连接，比较时忽略大小写及设备报告可能省略的连字符。底层使用设备报告的实际 serial；JSONL 回执保留输入的 UDID。拒绝自定义 usbmuxd 连接地址。设备选择、用户授权、会话 ID、请求有效期及不同客户端间的仲裁由主机协调器负责。
- 采用 UTF-8 的 newline-delimited JSON。每行一条 JSON 对象；宿主必须读取标准输出，诊断文本走 stderr。不要并发启动两个进程控制同一台设备。宿主应串行等待回执再发下一条命令。
- `requestID` 为最长 128 字符的非空字符串。此进程内已经执行的相同请求 ID 加相同命令参数复用原回执；不同参数复用同一 ID 会拒绝。新进程不重放旧请求，也不保存历史位置到文件。若指令额外携带 `deviceID`，则必须匹配启动目标。
- `set` 参数 `latitude`、`longitude` 为 WGS 84 十进制度（有限数值，分别在 `[-90, 90]`、`[-180, 180]`）。`clear` 为人工确认的同一目标清除操作，允许用于上次失联后的恢复；`quit` 结束辅助进程，并只在本进程可能曾设点且未清除时尝试清除。
- 用长驻进程保持会话，不要为每次设点创建一个新进程。命令回执只反映本地调用，旧会话控制和超时调度不能由辅助进程替代。主机还必须设置等待辅助进程的外部时限，并处理进程异常退出。

标准输出示例（实际输出每个对象占一行）：

```jsonl
{"event":"ready","deviceID":"用户选择的UDID","productVersion":"17.4.1","backendVersion":"11.62.0"}
{"event":"receipt","deviceID":"用户选择的UDID","requestID":"point-b","command":"set","status":"sent","message":"设点调用已返回；等待独立 Probe 确认"}
{"event":"receipt","deviceID":"用户选择的UDID","requestID":"clear-1","command":"clear","status":"sent","message":"清除调用已返回；真实位置是否恢复尚未知"}
```

| 事件/状态 | 语义 |
| --- | --- |
| `ready` | 连接准备完成；没有修改位置。 |
| `receipt / sent` | 本地 Python API 调用正常返回（或 `quit` 在无待清除会话时完成本地操作）。不是设备定位样本，也不是服务端对位置的独立确认。 |
| `receipt / rejected` | 参数不合法或已有请求 ID 与此次参数冲突；未发送修改指令。 |
| `receipt / unknown` | 调用异常或超时；设备状态不能确认，随后结束此进程且尽力清除本进程可能留下的模拟。 |
| `error / rejected` | 前置条件或输入检查失败。例如指定设备不匹配、未配对、系统范围不符。 |
| `error / unknown` | 连接失效或辅助进程异常；宿主应标记设备状态未知。 |
| `cleanup / sent` 或 `cleanup / unknown` | EOF、信号、异常退出时本进程尝试过清除的结果。未曾发起设点或已清除则不会自动修改设备。 |

退出码 `0` 为正常结束（不等同于确认真机恢复），`1` 为启动被拒绝，`2` 为其他失败或未知状态。`SIGINT`、`SIGTERM` 与 stdin EOF 都会尝试有序结束；强制杀进程、拔线、主机休眠/离线或传输故障后的恢复时间都需实测，不能依赖退出码。启动各步骤本地等待上限为 45 秒，DVT 操作等待上限为 15 秒；宿主需独立管理进程生命周期。传输关闭通过隧道状态轮询发现，DVT 通道异常可能在下一次命令才显现。

未知状态下，不应自动重放设点。从 Probe 记录当前状态后，确保重新选择同一真机并显式发送 `clear`，再从实际定位样本确认是否恢复到 A。清除请求的回执也不能替代恢复观测。

## 依据和仍待验证的内容

固定依赖 `pymobiledevice3==11.62.0` 的版本发布记录已核对：[PyPI 11.62.0](https://pypi.org/project/pymobiledevice3/11.62.0/)（2026-11-22，Python >= 3.9，GPL-3.0-or-later）。未打包上游分发物；若后续分发给用户，须单独确认 GPL 义务和第三方依赖许可。此文件不是法律结论。

公开 Python API 文档描述 `UserspaceRsdTunnel`、`DvtProvider` 与 `LocationSimulation` 的异步使用方式；从公开 API 可见开发定位接口不等待独立设备回执，因此本项目报告 `sent` 不报告设备已接受或已定位。发布脚本会在构建环境导入当前后端，并执行成品的 `--check-runtime` 核对固定版本。真机生效与恢复以手机上的独立定位样本为准。

在具备上述依赖的 Python 环境中，从项目根目录运行无真机回归：

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s swift/Tests/ModernHelper -v
```

核心会话测试使用标准库与本地输入管道。独立后端测试还导入固定版本的 `pymobiledevice3`，通过测试替身覆盖目标绑定、USB 优先、Wi-Fi 发现与开发镜像准备。

- [上游 Python API 指南](https://doronz88.github.io/pymobiledevice3/master/guides/python-api/)
- [上游连接 API](https://doronz88.github.io/pymobiledevice3/master/api/connection/)
- [上游 DVT API](https://doronz88.github.io/pymobiledevice3/master/api/dvt/)
- [上游 iOS 17+ 隧道说明](https://doronz88.github.io/pymobiledevice3/master/guides/ios17-tunnels/)
- [上游 CLI developer 命令手册](https://doronz88.github.io/pymobiledevice3/latest/cli/developer/)

P0 验收需用户实际记录：macOS、机型与系统版本、后端版本、USB 连接、A/B/C 的独立样本与来源字段、清除后实际恢复耗时。位置来源字段未知不能解释为普通真实位置；不提供检测规避功能，不承诺第三方应用一定接受模拟位置。朋友圈只可作为经许可的额外兼容性观察，须与实际 Probe 样本分别记录。
