#!/usr/bin/env python3
"""为 Android arm64 生成 Everywhere 本地安装与发布 APK，需要匹配的 Qt for Python Android wheels。"""
import argparse
import configparser
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


def stage(directory):
    """仅暂存手机端、共享地图、协议实现和此 APK 所需的配件身份。"""
    directory.mkdir()
    for name in ("main", "session"):
        shutil.copy2(QT / "android" / f"{name}.py", directory)
    for name in ("app_version", "mapview", "geo", "appearance"):
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
    build(parser.parse_args())
