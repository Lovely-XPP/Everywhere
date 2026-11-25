# Everywhere iAP2 客户端

固定上游版本见 NOTICE。客户端由 Python 标准库实现蓝牙传输，原生桥使用 Foundation 与 IOBluetooth。构建机需要 Xcode Command Line Tools、Python 3.11 或更高版本以及支持该 Python 版本的 PyInstaller 6。

打包时将项目 `asset/mfi` 的 `certificate.p7b` 和 `identity.pk8` 写入 Mac App 的 `Contents/Resources/asset/mfi/`，核对公钥一致后再签署 App。分发 ZIP 携带完整的配件签名身份，持有 App 的人可以读取私钥。新 Mac 复制 App 后即可打开「蓝牙模式 → 设备 → iAP2 配件」检测握手。收到 iPhone 的 `0xAA05` 表示认证通过。

在项目根目录针对待组装应用重建辅助程序时，运行 `EVERYWHERE_IAP2_PYTHON=/path/to/build-env/bin/python ./package.sh --iap2-helper /path/to/staged/Everywhere.app`。签名和分发整个 App 时，使用工程根目录的 `./package.sh`。

工程默认识别 Build/IAP2-Python/bin/python 作为构建解释器，也可以设置 EVERYWHERE_IAP2_PYTHON 覆盖路径。本次验证使用 PyInstaller 6.22.3。
