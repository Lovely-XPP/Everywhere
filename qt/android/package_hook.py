"""为 Android Qt TLS 插件提供 python-for-android 构建的 OpenSSL 3 库。"""
from pathlib import Path
import shutil


def before_apk_build(toolchain):
    """p4a 进入 Gradle 工程后，在原生库目录补齐 Qt 查找的带版本文件名。"""
    directory = Path.cwd() / "libs" / "arm64-v8a"
    for name in ("libssl", "libcrypto"):
        shutil.copyfile(directory / f"{name}.so", directory / f"{name}_3.so")
