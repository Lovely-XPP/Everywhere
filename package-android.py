#!/usr/bin/env python3
"""为 Android arm64 生成 Everywhere 本地安装与发布 APK，需要匹配的 Qt for Python Android wheels。"""
import argparse
import configparser
import fcntl
import hashlib
import json
import platform as host_platform
import re
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile

from qt.android_toolchain import available_apis, require_packages, sdkmanager, select

ROOT = Path(__file__).resolve().parent
QT = ROOT / "qt"
CLIENT = ROOT / "swift/Host/IAP2Client"
# 保留现有缓存键的兼容标识；仅在修改原生构建规则且旧产物不兼容时更新。
# APK 组装、签名、资源检查和业务源码变化不应使原生 recipe 缓存失效。
NATIVE_BUILD_REVISION = "98b57f4f1ea3ad174b54c1a7b7a3e87060b2e6bdc838d7814201dd5a6a04c2f4"


def stage(directory):
    """仅暂存手机端、共享地图、协议实现和此 APK 所需的配件身份。"""
    directory.mkdir()
    for name in ("main", "session"):
        shutil.copy2(QT / "android" / f"{name}.py", directory)
    for name in ("app_version", "mapview", "geo", "appearance", "core", "dialogs",
                 "console_ui", "place_browser"):
        shutil.copy2(QT / f"{name}.py", directory)
    shutil.copytree(CLIENT / "src/accessory_location", directory / "accessory_location",
                    ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    for name in ("NOTICE", "LICENSE"):
        shutil.copy2(CLIENT / name, directory / f"{name}.txt")
    (directory / "mfi").mkdir()
    for name in ("certificate.p7b", "identity.pk8"):
        shutil.copy2(ROOT / "asset/mfi" / name, directory / "mfi" / name)


def stage_sdk(destination, sdk, api, platform, tools_dir):
    """为本次构建提供所选平台和工具，兼容 Buildozer 的整级平台名和旧工具路径。"""
    manager = sdkmanager(sdk)
    if not manager:
        raise SystemExit(f"缺少可执行的 Android SDK Command-line Tools：{sdk}")
    destination.mkdir()
    for entry in sdk.iterdir():
        if entry.name not in ("platforms", "build-tools", "tools"):
            (destination / entry.name).symlink_to(entry)
    for relative, source in ((f"platforms/android-{api}", platform),
                             (f"build-tools/{tools_dir.name}", tools_dir),
                             ("tools/bin/sdkmanager", manager.resolve()),
                             ("tools/bin/avdmanager", manager.with_name("avdmanager").resolve())):
        link = destination / relative
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(source)
    subprocess.run([destination / "tools/bin/sdkmanager", f"--sdk_root={destination}", "--version"],
                   check=True)
    if int(api) not in available_apis(destination):
        raise SystemExit(f"临时 SDK 中 avdmanager 未列出选定的 API {api}：{platform}")


def cached_p4a(branch):
    """首次下载 Qt 所需的 python-for-android 分支，后续构建复用完整源码。"""
    cache = ROOT / "Build" / "AndroidEnv" / "downloads"
    cache.mkdir(parents=True, exist_ok=True)
    destination = cache / f"python-for-android-{branch}"
    if not destination.exists():
        with tempfile.TemporaryDirectory(prefix="p4a-", dir=cache) as temporary:
            checkout = Path(temporary) / "source"
            subprocess.run(["git", "clone", "-b", branch, "--single-branch",
                            "https://github.com/kivy/python-for-android.git", checkout], check=True)
            checkout.rename(destination)
    if not (destination / "setup.py").is_file():
        raise SystemExit(f"python-for-android 源码缓存不完整：{destination}")
    return destination


def link_recipe_cache(build_dir, cache):
    """将 arm64 构建的源码下载目录链接到持久缓存，保留 p4a 完成标记。

    build_dir 为本次 Buildozer 工作目录，cache 为跨构建复用的绝对路径。
    不同工具链的编译目录共享下载包。
    """
    cache.mkdir(parents=True, exist_ok=True)
    packages = build_dir / "android/platform/build-arm64-v8a/packages"
    packages.parent.mkdir(parents=True, exist_ok=True)
    if not packages.is_symlink():
        packages.symlink_to(cache, target_is_directory=True)
    elif packages.resolve() != cache.resolve():
        raise SystemExit(f"recipe 下载缓存路径不匹配：{packages}")


def build_cache_key(args, app, sdk, platform, tools_dir, ndk, minimum, mode):
    """按工具链、构建配置及 wheel 内容计算本机编译缓存键，不依赖业务源码版本。"""
    from importlib.metadata import version

    def digest(path):
        result = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                result.update(chunk)
        return result.hexdigest()

    p4a = Path(app["p4a.source_dir"])
    inputs = {
        "schema": 1, "host": [sys.platform, host_platform.machine(), host_platform.release()],
        "python": [sys.executable, sys.version], "mode": mode, "minimum": minimum,
        "sdk": str(sdk), "api": app["android.api"], "requirements": app["requirements"],
        "bootstrap": app["p4a.bootstrap"],
        # Qt 部署工具通过 set 生成模块列表，不同进程的顺序可能不同。
        "qt_args": sorted((flag.partition("=")[0], sorted(flag.partition("=")[2].split(",")))
                          for flag in app["p4a.extra_args"].split()),
        "p4a": subprocess.check_output(["git", "-C", p4a, "rev-parse", "HEAD"], text=True).strip(),
        "p4a_changes": hashlib.sha256(subprocess.check_output(["git", "-C", p4a, "diff", "HEAD"])).hexdigest(),
        "host_packages": {name: version(name) for name in ("PySide6", "shiboken6", "buildozer", "Cython", "setuptools")},
        "tools": [str(path.resolve()) + ":" + (digest(path / "source.properties")
                                              if (path / "source.properties").is_file() else "")
                  for path in (platform, tools_dir, ndk)],
        "sdkmanager": str(sdkmanager(sdk).resolve()),
        "build_script": NATIVE_BUILD_REVISION,
        "wheels": [(str(path.resolve()), digest(path)) for path in (args.pyside, args.shiboken)],
        "environment": {key: os.environ.get(key, "") for key in
                        ("JAVA_HOME", "CC", "CXX", "CFLAGS", "CPPFLAGS", "LDFLAGS", "SDKROOT")},
    }
    return hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()[:24]


def build_cache_root():
    """选择固定的纯 ASCII 编译路径；不同项目的外部缓存按绝对路径隔离。"""
    def compatible(path):
        return str(path).isascii() and not any(char.isspace() for char in str(path))

    override = os.getenv("EVERYWHERE_ANDROID_BUILD_CACHE")
    project_cache = (ROOT / "Build" / "AndroidEnv" / "build").resolve()
    if not override and compatible(project_cache):
        return project_cache
    if override:
        base = Path(override).expanduser().resolve()
    elif sys.platform == "darwin":
        base = (Path.home() / "Library" / "Caches" / "Everywhere" / "android").resolve()
    else:
        base = (Path(os.getenv("XDG_CACHE_HOME") or Path.home() / ".cache") / "everywhere" / "android").resolve()
    if not compatible(base):
        raise SystemExit("Android 原生编译缓存路径必须为纯 ASCII 且不含空白，请设置 EVERYWHERE_ANDROID_BUILD_CACHE。")
    project_key = hashlib.sha256(str(ROOT).encode()).hexdigest()[:16]
    return base / project_key


def configure_host_make(env, temporary):
    """macOS 原生依赖构建统一使用新版 GNU Make，避免系统 Make 3.81 导致 Automake 失败。"""
    if sys.platform != "darwin":
        return
    gmake = shutil.which("gmake", path=env.get("PATH"))
    if not gmake:
        raise SystemExit("Android 在 macOS 上需要新版 GNU Make，请执行 brew install make。")
    tools = Path(temporary) / "host-bin"
    tools.mkdir(exist_ok=True)
    make = tools / "make"
    if make.is_symlink():
        make.unlink()
    make.symlink_to(Path(gmake).resolve())
    # p4a 在原生 recipe 中直接调用 make，并自行设置 MAKE，必须通过 PATH 选择。
    env["PATH"] = str(tools) + os.pathsep + env.get("PATH", os.defpath)


def stage_qt_android_jar(wheel, destination, name):
    """从同版本 Android wheel 提取部署工具遗漏的 Java 依赖，返回绝对 JAR 路径。"""
    destination.mkdir(parents=True, exist_ok=True)
    path = destination / name
    with zipfile.ZipFile(wheel) as archive:
        with archive.open(f"PySide6/jar/{name}") as source, path.open("wb") as target:
            shutil.copyfileobj(source, target)
    return path.resolve()


def verify_qt_android_classes(apk, dexdump, directory):
    """检查 DEX 实际定义的 Qt Java 类，缺失时拒绝发布 APK。"""
    required = {"Lorg/qtproject/qt/android/bluetooth/QtBluetoothBroadcastReceiver;"}
    with zipfile.ZipFile(apk) as archive:
        for name in archive.namelist():
            if not re.fullmatch(r"classes\d*\.dex", name):
                continue
            dex = directory / name
            dex.write_bytes(archive.read(name))
            definitions = subprocess.check_output([dexdump, dex], text=True)
            required.difference_update(re.findall(r"Class descriptor\s*:\s*'([^']+)'", definitions))
    if required:
        raise SystemExit(f"APK 缺少 Qt Android Java 类：{', '.join(sorted(required))}")


def build(args):
    from importlib.metadata import version
    deploy = shutil.which("pyside6-android-deploy")
    if not deploy:
        raise SystemExit("构建环境缺少 pyside6-android-deploy。请在 PySide6 虚拟环境中运行。")
    for path, name in ((args.pyside, "pyside6"), (args.shiboken, "shiboken6")):
        parts = path.name.lower().split("-")
        if (not path.is_file() or len(parts) < 5 or parts[0] != name or
                parts[1] != version(name).lower() or "android" not in parts[-1]
                or "aarch64" not in parts[-1] and "arm64" not in parts[-1]):
            raise SystemExit(f"需要与宿主 {name} 版本一致的 Android arm64 wheel：{path}")
    if version("pyside6") != "6.8.3":
        raise SystemExit("Android 构建使用 Qt for Python 6.8.3。")
    minimum = 28
    mode = "release" if args.release else "debug"
    sdk = args.sdk.resolve()
    android_api, platform, build_tools, ndk, missing = select(sdk, args.ndk or os.getenv("ANDROID_NDK_ROOT"))
    require_packages(missing)
    tools_dir = sdk / "build-tools" / build_tools

    if args.release:
        signing = ROOT / "asset/android-signing"
        keystore = Path(os.environ.get("EVERYWHERE_ANDROID_KEYSTORE", signing / "release.p12"))
        password = Path(os.environ.get("EVERYWHERE_ANDROID_PASSWORD_FILE", signing / "password"))
        alias = os.environ.get("EVERYWHERE_ANDROID_KEY_ALIAS", "everywhere")
        if not keystore.is_file() or not password.is_file():
            raise SystemExit("缺少 Android 发布签名材料，请设置发布密钥和密码文件路径。")
    from runpy import run_path
    release = run_path(str(QT / "app_version.py"))["VERSION"]
    output = ROOT / "Build" / "Android"
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="everywhere-android-") as temporary:
        directory = Path(temporary) / "app"
        build_sdk = Path(temporary) / "sdk"
        stage_sdk(build_sdk, sdk, android_api, platform, tools_dir)
        env = dict(os.environ, ANDROID_SDK_ROOT=str(build_sdk), ANDROID_HOME=str(build_sdk),
                   ANDROID_NDK_ROOT=str(ndk))
        stage(directory)
        deploy_args = [deploy, "--init", "--keep-deployment-files", "--name", "Everywhere",
                       "--wheel-pyside", str(args.pyside.resolve()),
                       "--wheel-shiboken", str(args.shiboken.resolve()),
                       "--extra-modules", "Core,Gui,Widgets,Network,Bluetooth"]
        deploy_args.extend(["--sdk-path", str(build_sdk), "--ndk-path", str(ndk)])
        subprocess.run(deploy_args, cwd=directory, env=env, check=True)
        spec = directory / "buildozer.spec"
        if not spec.is_file():
            raise SystemExit("Qt 部署工具未生成 Buildozer 配置，不能继续打包。")
        config = configparser.ConfigParser(interpolation=None)
        config.read(spec, encoding="utf-8")
        app = config["app"]
        app.update({"package.name": "everywhere", "package.domain": "com.virtuallocation",
                    "version": release, "android.archs": "arm64-v8a",
                    "icon.filename": str(ROOT / "swift/Apps/Mobile/Mobile/Assets.xcassets/AppIcon.appiconset/AppIcon.png"),
                    "orientation": "portrait, landscape, portrait-reverse, landscape-reverse",
                    "android.minapi": str(minimum), "android.ndk_api": str(minimum),
                    "android.permissions": "android.permission.INTERNET,"
                    "(name=android.permission.BLUETOOTH;maxSdkVersion=30),"
                    "android.permission.BLUETOOTH_CONNECT,"
                    "(name=android.permission.BLUETOOTH_SCAN;usesPermissionFlags=neverForLocation)",
                    "android.debug_artifact": "apk"})
        app["android.api"] = android_api
        app["android.sdk_path"] = str(build_sdk)
        app["android.ndk_path"] = str(ndk)
        app["android.skip_update"] = "True"
        app["android.release_artifact"] = "apk"
        # Qt 6.8.3 的部署工具没有将 Bluetooth JNI 所需的 JAR 加入 Gradle。
        bluetooth_jar = stage_qt_android_jar(args.pyside, Path(temporary) / "qt-jars",
                                             "Qt6AndroidBluetooth.jar")
        app["android.add_jars"] = ",".join(filter(None, (app.get("android.add_jars", ""),
                                                         str(bluetooth_jar))))
        app["p4a.source_dir"] = str(cached_p4a(app["p4a.branch"]))
        # 官方 Android wheels 的解释器 ABI 是 cp311。
        requirements = [r.strip() for r in app["requirements"].split(",")
                        if r.split("==")[0].strip() not in ("python3", "hostpython3")]
        app["requirements"] = ",".join(["python3==3.11.5", "hostpython3==3.11.5", *requirements])
        app.pop("version.regex", None)
        app.pop("version.filename", None)
        for key, extra in (("requirements", "pyjnius,cryptography"),
                           ("source.include_exts", "txt,p7b,pk8"),
                           ("source.exclude_dirs", "deployment,bin")):
            app[key] = ",".join(filter(None, (app.get(key, ""), extra)))
        recipe_cache = ROOT / "Build" / "AndroidEnv" / "packages"
        recipe_cache.mkdir(parents=True, exist_ok=True)
        cache_key = build_cache_key(args, app, sdk, platform, tools_dir, ndk, minimum, mode)
        cache_dir = build_cache_root() / cache_key
        # 串行访问下载和编译缓存，防止多个构建同时修改同一目录。
        with (recipe_cache / ".build.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if args.clean and cache_dir.is_dir():
                shutil.rmtree(cache_dir)
            build_dir = cache_dir / "buildozer"
            print(f"Android 编译缓存：{'复用' if build_dir.exists() else '首次构建'} {cache_dir}", flush=True)
            cache_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
            # SDK 与原生编译目录必须使用固定绝对路径，避免 Makefile 引用已删除的临时目录。
            stable_sdk = cache_dir / "sdk"
            if not stable_sdk.exists():
                shutil.move(str(build_sdk), str(stable_sdk))
            env.update(ANDROID_SDK_ROOT=str(stable_sdk), ANDROID_HOME=str(stable_sdk))
            configure_host_make(env, cache_dir)
            app["android.sdk_path"] = str(stable_sdk)
            link_recipe_cache(build_dir, recipe_cache)
            config["buildozer"]["build_dir"] = str(build_dir)
            config["buildozer"]["bin_dir"] = str(Path(temporary) / "apk")
            with spec.open("w", encoding="utf-8") as out:
                config.write(out)
            subprocess.run([sys.executable, "-m", "buildozer", "android", mode], cwd=directory, env=env, check=True)
        apks = list((Path(temporary) / "apk").glob("*.apk"))
        if len(apks) != 1:
            raise SystemExit("构建未生成唯一的 APK。")
        with zipfile.ZipFile(apks[0]) as archive:
            if ("AndroidManifest.xml" not in archive.namelist() or archive.testzip() is not None
                    or not any(n.startswith("lib/arm64-v8a/") for n in archive.namelist())):
                raise SystemExit("APK 的清单、架构或完整性检查失败。")
        artifact = apks[0]
        verify_qt_android_classes(artifact, tools_dir / "dexdump", Path(temporary))
        manifest = subprocess.check_output([tools_dir / "aapt", "dump", "badging", artifact], text=True)
        if not re.search(r"^sdkVersion:'28'$", manifest, re.MULTILINE):
            raise SystemExit("最终 APK 清单未声明最低 API 28。")
        if args.release:
            if "application-debuggable" in manifest:
                raise SystemExit("发布 APK 带有调试标志。")
            aligned = Path(temporary) / "aligned.apk"
            subprocess.run([tools_dir / "zipalign", "-P", "16", "-f", "4", artifact, aligned], check=True)
            artifact = Path(temporary) / "signed.apk"
            subprocess.run([tools_dir / "apksigner", "sign", "--ks", keystore, "--ks-key-alias", alias,
                            "--ks-pass", f"file:{password}", "--out", artifact, aligned], check=True)
        subprocess.run([tools_dir / "apksigner", "verify", "--min-sdk-version", "28", artifact], check=True)
        final = output / f"Everywhere-{release}-arm64-{mode}.apk"
        with tempfile.NamedTemporaryFile(dir=output, delete=False) as dest:
            with artifact.open("rb") as source:
                shutil.copyfileobj(source, dest)
        Path(dest.name).replace(final)
        print(final)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pyside", type=Path, required=True)
    parser.add_argument("--shiboken", type=Path, required=True)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--release", action="store_true", help="生成并验证 APK 发布签名")
    parser.add_argument("--ndk", type=Path)
    parser.add_argument("--clean", action="store_true", help="清除当前工具链的编译缓存后重新构建，保留下载缓存")
    build(parser.parse_args())
