"""选择 Android 打包工具链。准备环境与独立打包入口共用相同的版本和完整性检查。"""
import argparse
import os
import re
import subprocess
from pathlib import Path

# 项目目标 API 的选择下限，与 APK 的最低安装 API 28 独立。
MIN_TARGET_API = 34
MIN_BUILD_TOOLS = (35, 0, 0)
TOOLS = ("aapt", "aapt2", "aidl", "apksigner", "zipalign")
# Qt 6.8 的两套官方 Android NDK，缺失时沿用项目的 r26b。
NDK_REVISIONS = ("26.1.10909125", "27.2.12479018")


def directories(root):
    """返回已有的子目录，允许 SDK 尚未安装对应组件。"""
    return [path for path in root.iterdir() if path.is_dir()] if root.is_dir() else []


def executable(path):
    return path.is_file() and os.access(path, os.X_OK)


def revision(name):
    """按数值比较稳定版本，忽略预览版。"""
    if re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", name):
        return tuple(map(int, name.split(".")))
    return ()


def sdkmanager(sdk):
    """查找已有的 latest、数字版本或旧版 Command-line Tools 入口。"""
    root = sdk / "cmdline-tools"
    versions = sorted((p for p in directories(root) if revision(p.name)),
                      key=lambda p: revision(p.name), reverse=True)
    for directory in (root / "latest", *versions, sdk / "tools"):
        manager = directory / "bin/sdkmanager"
        if executable(manager):
            return manager
    return None


def available_apis(sdk):
    """按 python-for-android 的 list target 格式读取该 SDK 可用于构建的 API。"""
    manager = sdkmanager(sdk)
    if not manager or not executable(manager.with_name("avdmanager")):
        raise SystemExit(f"Android SDK 缺少 avdmanager，请安装完整的 Command-line Tools：{sdk}")
    env = dict(os.environ, ANDROID_HOME=str(sdk), ANDROID_SDK_ROOT=str(sdk))
    targets = subprocess.check_output([manager.with_name("avdmanager"), "list", "target"],
                                      env=env, text=True)
    return {int(value) for value in re.findall(r"^ *API level: ([0-9]+)", targets, re.M)}


def ndk_revision(path):
    """从安装元数据读取 NDK 版本，同时检查原生构建工具是否存在。"""
    properties = path / "source.properties"
    if properties.is_file() and executable(path / "ndk-build"):
        match = re.search(r"^Pkg\.Revision\s*=\s*([\d.]+)\s*$", properties.read_text(), re.M)
        if match:
            return match[1]
    return None


def select(sdk, ndk_override=None):
    """按安装内容选择目标 API、平台目录、Build Tools 和 NDK，并列出缺少的包。"""
    missing = []
    # Buildozer 的 android.api 接受整数。新版 SDK 可把同一整级平台命名为 android-N.0。
    platforms = {}
    for directory in directories(sdk / "platforms"):
        match = re.fullmatch(r"android-([1-9][0-9]*)(?:\.0)?", directory.name)
        if not match or int(match[1]) < MIN_TARGET_API or not (directory / "android.jar").is_file():
            continue
        properties = directory / "source.properties"
        if properties.is_file():
            metadata = dict(line.split("=", 1) for line in properties.read_text().splitlines() if "=" in line)
            if metadata.get("AndroidVersion.CodeName", "").strip() not in ("", "REL"):
                continue
        api = int(match[1])
        if api not in platforms or directory.name == f"android-{api}":
            platforms[api] = directory
    requested = os.getenv("EVERYWHERE_ANDROID_API")
    if requested and (not re.fullmatch(r"[1-9][0-9]*", requested) or int(requested) < MIN_TARGET_API):
        raise SystemExit(f"需要 API {MIN_TARGET_API} 或更新的整级平台：{requested}")
    visible = available_apis(sdk)
    usable = platforms.keys() & visible
    api = int(requested) if requested else max(usable, default=MIN_TARGET_API)
    if api in platforms and api not in visible:
        raise SystemExit(f"平台 {platforms[api].name} 已安装，但 avdmanager 未列出 API {api}。"
                         f"请更新 Command-line Tools 或选择可见的稳定平台。可见 API：{sorted(visible)}")
    platform = platforms.get(api, sdk / f"platforms/android-{api}")
    if api not in platforms:
        missing.append(f"platforms;android-{api}")

    build_root = sdk / "build-tools"
    build = os.getenv("EVERYWHERE_ANDROID_BUILD_TOOLS")
    if build and (not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", build)
                  or revision(build) < MIN_BUILD_TOOLS):
        raise SystemExit(f"需要 35.0.0 或更新的稳定版 Build Tools：{build}")
    builds = [p.name for p in directories(build_root)
              if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", p.name)
              and revision(p.name) >= MIN_BUILD_TOOLS
              and all(executable(p / tool) for tool in TOOLS)]
    build = build or max(builds, key=revision, default="35.0.0")
    if build not in builds:
        missing.append(f"build-tools;{build}")

    root = sdk / "ndk"
    if ndk_override:
        ndk = Path(ndk_override).expanduser().resolve()
        if ndk_revision(ndk) not in NDK_REVISIONS:
            if not ndk.exists() and ndk.parent == root and ndk.name in NDK_REVISIONS:
                missing.append(f"ndk;{ndk.name}")
            else:
                raise SystemExit(f"指定的 NDK 缺少可执行工具或版本不匹配（需要 r26b 或 r27c）：{ndk}")
    else:
        ndk = next((root / v for v in reversed(NDK_REVISIONS)
                    if ndk_revision(root / v) == v), root / NDK_REVISIONS[0])
        if ndk_revision(ndk) not in NDK_REVISIONS:
            missing.append(f"ndk;{ndk.name}")
    if not executable(sdk / "platform-tools/adb"):
        missing.append("platform-tools")
    return str(api), platform, build, ndk, missing


def require_packages(missing):
    if missing:
        raise SystemExit("Android SDK 仍缺少组件：" + ", ".join(missing))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("sdk", type=Path)
    parser.add_argument("--manager", action="store_true", help="输出可用的 sdkmanager 路径")
    args = parser.parse_args()
    sdk = args.sdk.resolve()
    manager = sdkmanager(sdk)
    if args.manager:
        print(manager or "")
    else:
        api, platform, build, ndk, missing = select(sdk, os.getenv("ANDROID_NDK_ROOT"))
        print(f"Android SDK {sdk}，目标 API {api}（{platform.name}），Build Tools {build}，NDK {ndk}", flush=True)
        if missing:
            if not manager:
                raise SystemExit("缺少 Android SDK Command-line Tools。")
            print("安装缺少的 SDK 组件：" + ", ".join(missing), flush=True)
            subprocess.run([manager, f"--sdk_root={sdk}", *missing], check=True)
            require_packages(select(sdk, os.getenv("ANDROID_NDK_ROOT"))[-1])
