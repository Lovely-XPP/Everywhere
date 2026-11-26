#!/bin/bash
# Everywhere Apple 平台发布入口。所有步骤以脚本位置为基准，完整验证后才切换最新版本。
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")" && pwd -P)
host="$root/swift/Host"
identity=${MAC_SIGN_IDENTITY:--}
bundle_identity=${EVERYWHERE_BUNDLE_MFI_IDENTITY:-1}
mode=all
die() { printf '%s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
用法：./package.sh [--mac-only | --ios-only] [导出父目录]
默认同时导出 Mac App、macOS ZIP、iPhone/iPad IPA；Build/Everywhere 指向最近一次完整导出。
单组件重建：./package.sh --iap2-helper 已暂存的.app
Mac 签名：MAC_SIGN_IDENTITY；自备 Python：EVERYWHERE_IAP2_PYTHON、EVERYWHERE_PORTABLE_PYTHON。
HELP
}
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --mac-only) mode=mac; shift ;;
    --ios-only) mode=ios; shift ;;
    --iap2-helper) mode=iap2; shift ;;
    -*) usage >&2; exit 2 ;;
esac
(( $# <= 1 )) || die '最多指定一个输出目录。'
[[ $(uname -s) == Darwin ]] || die 'Swift 发布需要 macOS 与完整 Xcode。'

# Python 打包子进程及构建工具不继承 iOS 签名密码。
ios_password_provided=${EVERYWHERE_IOS_P12_PASSWORD+x}
ios_password=${EVERYWHERE_IOS_P12_PASSWORD-}
unset EVERYWHERE_IOS_P12_PASSWORD
if [[ -z ${DEVELOPER_DIR:-} ]] && ! xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/everywhere-build.XXXXXXXX")
stage=''
link_stage=''
cleanup() {
    rm -rf -- "$work"
    if [[ -n "$stage" ]]; then rm -rf -- "$stage"; fi
    if [[ -n "$link_stage" ]]; then rm -rf -- "$link_stage"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export CLANG_MODULE_CACHE_PATH=${CLANG_MODULE_CACHE_PATH:-"$work/module-cache"}
export PYTHONDONTWRITEBYTECODE=1 PYINSTALLER_CONFIG_DIR="$work/pyinstaller-cache"

# 显式指定的 Python 只做校验。默认依赖安装到项目专属虚拟环境。
build_python() {
    local kind=$1 override envdir python base
    if [[ $kind == iap2 ]]; then
        override=${EVERYWHERE_IAP2_PYTHON:-}
        envdir="$root/Build/IAP2-Python"
    else
        override=${EVERYWHERE_PORTABLE_PYTHON:-}
        envdir="$root/Build/Portable-Python"
    fi
    python=${override:-"$envdir/bin/python"}
    if [[ -z "$override" && ! -x "$python" ]]; then
        base=${EVERYWHERE_IAP2_PYTHON:-"$root/Build/IAP2-Python/bin/python"}
        if [[ ! -x "$base" ]]; then
            base=$(command -v python3.13 || command -v python3.12 || command -v python3.11 || command -v python3)
        fi
        "$base" -c 'import sys; assert sys.version_info >= (3,11), "需要 Python 3.11+"' >&2
        "$base" -m venv "$envdir" >&2
    fi
    local deps=('PyInstaller>=6,<7')
    if [[ $kind == portable ]]; then deps+=(-r "$host/ModernBackend/requirements.txt"); fi
    if ! check_python "$python" "$kind"; then
        [[ -z "$override" ]] || die "指定的 Python 未满足 $kind 构建依赖：$python"
        "$python" -m pip install "${deps[@]}" >&2
        check_python "$python" "$kind" || die "$kind 的 Python 环境校验失败。"
    fi
    printf '%s\n' "$python"
}

check_python() {
    "$1" - "$2" "$host/ModernBackend" <<'PY' 2>/dev/null
import sys
from importlib.metadata import version
from pathlib import Path
assert sys.version_info >= (3, 11) and version("PyInstaller").split(".")[0] == "6"
if sys.argv[1] == "portable":
    sys.path.insert(0, sys.argv[2])
    import portable_location as backend
    pin = "pymobiledevice3==" + backend.BACKEND_VERSION
    assert pin in (Path(sys.argv[2]) / "requirements.txt").read_text().splitlines()
    assert version("pymobiledevice3") == backend.BACKEND_VERSION
PY
}

freeze_helper() {
    local python=$1 name=$2 bundle_id=$3
    shift 3
    local options=(--noconfirm --clean --onedir --windowed --noupx --name "$name"
        --distpath "$work/dist" --workpath "$work/freeze" --specpath "$work"
        --osx-bundle-identifier "$bundle_id")
    if [[ "$identity" != - ]]; then options+=(--codesign-identity "$identity"); fi
    "$python" -m PyInstaller "${options[@]}" "$@"
}

package_iap2() {
    local app=$1 python=$2 src="$host/IAP2Client" helper="$1/Contents/Helpers"
    local notices="$app/Contents/Resources/IAP2" credentials="$app/Contents/Resources/asset/mfi"
    mkdir -p "$helper" "$notices" "$credentials"
    freeze_helper "$python" accessory-location com.virtuallocation.iap2client --paths "$src/src" "$src/main.py"
    ditto "$work/dist/accessory-location.app" "$helper/AccessoryLocation.app"
    local plist="$helper/AccessoryLocation.app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :LSBackgroundOnly bool true' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :NSBluetoothAlwaysUsageDescription string 通过经典蓝牙访问已配对的 iPhone。' "$plist"
    xcrun clang -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$src/BridgeInfo.plist" \
        -fobjc-arc -framework Foundation -framework IOBluetooth "$src/native/bluetooth_bridge.m" -o "$helper/bluetooth-bridge"
    MACOSX_DEPLOYMENT_TARGET=14.0 xcrun swiftc -O "$src/native/mfi_auth.swift" -o "$helper/mfi-auth"
    if [[ $bundle_identity != 0 ]]; then
        install -m 644 "$root/asset/mfi/certificate.p7b" "$credentials/"
        install -m 644 "$root/asset/mfi/identity.pk8" "$credentials/"
    fi
    local tool
    for tool in AccessoryLocation.app bluetooth-bridge mfi-auth; do
        codesign --force --sign "$identity" "$helper/$tool"
        codesign --verify --strict "$helper/$tool"
    done
    if [[ $bundle_identity != 0 ]]; then "$helper/mfi-auth" verify-bundle; fi
    cp "$src/LICENSE" "$src/NOTICE" "$notices/"
    "$python" - "$notices" <<'PY'
from importlib import metadata
from pathlib import Path
import shutil, sys, sysconfig
dest = Path(sys.argv[1])
shutil.copyfile(Path(sysconfig.get_path("stdlib")) / "LICENSE.txt", dest / "CPython-LICENSE.txt")
dist = metadata.distribution("pyinstaller")
license_file = next(f for f in dist.files if f.name == "COPYING.txt")
shutil.copyfile(dist.locate_file(license_file), dest / "PyInstaller-LICENSE.txt")
PY
    # 保留重建对应源码所需的项目相对路径，只列入源码、许可证与脚本。
    COPYFILE_DISABLE=1 tar -czf "$notices/source.tar.gz" --exclude='__pycache__' --exclude='.DS_Store' -C "$root" \
        package.sh swift/Host/IAP2Client/{src,native,main.py,BridgeInfo.plist,LICENSE,NOTICE,README.md}
    "$helper/AccessoryLocation.app/Contents/MacOS/accessory-location" send --help >/dev/null
}

package_backend() {
    local dest="$1/Contents/Helpers/DeviceLocation.app" src="$host/ModernBackend" python
    local cached="$root/Build/Everywhere/Everywhere.app/Contents/Helpers/DeviceLocation.app" fingerprint
    fingerprint=$(cd "$root" && { uname -m; shasum -a 256 package.sh swift/Host/ModernBackend/{modern_backend.py,portable_location.py,requirements.txt}; } | shasum -a 256 | cut -d' ' -f1)
    # 缓存元数据与辅助程序一起签名；显式选择 Python 或签名身份时总是从源码构建。
    if [[ -z ${EVERYWHERE_PORTABLE_PYTHON:-} && "$identity" == - && -d "$cached" ]] &&
       [[ $(/usr/libexec/PlistBuddy -c 'Print :EverywhereBuildInputs' "$cached/Contents/Info.plist" 2>/dev/null) == "$fingerprint" ]] &&
       codesign --verify --deep --strict "$cached"; then
        ditto "$cached" "$dest"
        "$dest/Contents/MacOS/DeviceLocation" --check-runtime
        return
    fi
    python=$(build_python portable)
    freeze_helper "$python" DeviceLocation com.virtuallocation.device-location \
        --recursive-copy-metadata pymobiledevice3 --collect-data pymobiledevice3 --collect-data developer_disk_image \
        --collect-submodules pytcp --exclude-module IPython --exclude-module pytest "$src/portable_location.py"
    ditto "$work/dist/DeviceLocation.app" "$dest"
    local plist="$dest/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :LSBackgroundOnly bool true' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :NSLocalNetworkUsageDescription string 发现并连接已配对的 iPhone 或 iPad。' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :NSBonjourServices array' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :NSBonjourServices:0 string _apple-mobdev2._tcp' "$plist"
    /usr/libexec/PlistBuddy -c "Add :EverywhereBuildInputs string $fingerprint" "$plist"
    codesign --force --sign "$identity" "$dest"
    "$dest/Contents/MacOS/DeviceLocation" --check-runtime
}

package_mac() {
    local app="$stage/Everywhere.app" products iap_python
    if [[ $bundle_identity != 0 ]]; then
        [[ -r "$root/asset/mfi/certificate.p7b" && -r "$root/asset/mfi/identity.pk8" ]] || die '缺少 asset/mfi 配件身份。'
    fi
    iap_python=$(build_python iap2)
    local opts=(--package-path "$root/swift" --scratch-path "$work/mac" --cache-path "$work/cache" --configuration release)
    if [[ ${EVERYWHERE_NESTED_SANDBOX:-0} == 1 ]]; then opts+=(--disable-sandbox); fi
    xcrun swift build "${opts[@]}" --product MacHost
    products=$(xcrun swift build "${opts[@]}" --show-bin-path)
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$host/MacApp/Info.plist" "$app/Contents/"
    cp "$host/MacApp/VirtualLocation.icns" "$app/Contents/Resources/"
    cp "$products/MacHost" "$app/Contents/MacOS/"
    ditto "$products/VirtualLocation_ModernHelper.bundle" "$app/Contents/Resources/VirtualLocation_ModernHelper.bundle"
    package_iap2 "$app" "$iap_python"
    package_backend "$app"
    codesign --force --sign "$identity" "$app"
    codesign --verify --deep --strict "$app"
    ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/Everywhere-macOS.zip"
    ditto -x -k "$stage/Everywhere-macOS.zip" "$work/mac-verify"
    codesign --verify --deep --strict "$work/mac-verify/Everywhere.app"
    if [[ $bundle_identity != 0 ]]; then "$work/mac-verify/Everywhere.app/Contents/Helpers/mfi-auth" verify-bundle; fi
}

package_ios() {
    xcrun --sdk iphoneos --show-sdk-path >/dev/null || die '请将 DEVELOPER_DIR 指向完整 Xcode 的 Contents/Developer。'
    local opts=(CODE_SIGNING_ALLOWED=NO)
    if [[ ${EVERYWHERE_NESTED_SANDBOX:-0} == 1 ]]; then opts+=('OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -disable-sandbox'); fi
    xcrun xcodebuild -quiet -project "$root/swift/Apps/Mobile/Mobile.xcodeproj" -scheme Mobile \
        -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
        -derivedDataPath "$work/ios" "${opts[@]}" build
    local app="$work/ios/Build/Products/Release-iphoneos/Everywhere.app"
    local plist="$app/Info.plist"
    [[ -x "$app/Everywhere" && ! -e "$app/embedded.mobileprovision" && ! -e "$app/_CodeSignature" ]]
    if codesign -d "$app" >/dev/null 2>&1; then die '预期为未签名 iOS 构建。'; fi
    [[ $(/usr/libexec/PlistBuddy -c 'Print :DTPlatformName' "$plist") == iphoneos ]]
    [[ $(/usr/libexec/PlistBuddy -c 'Print :UIDeviceFamily:0' "$plist") == 1 ]]
    [[ $(/usr/libexec/PlistBuddy -c 'Print :UIDeviceFamily:1' "$plist") == 2 ]]
    mkdir "$work/Payload"
    mv "$app" "$work/Payload/"
    (cd "$work" && /usr/bin/zip -qry "$stage/Everywhere.ipa" Payload)
    /usr/bin/unzip -tq "$stage/Everywhere.ipa"
    local credentials="$root/asset/ios-signing"
    if [[ -d "$credentials" ]]; then
        if [[ -n "$ios_password_provided" ]]; then
            EVERYWHERE_IOS_P12_PASSWORD="$ios_password" /usr/bin/python3 "$host/iOSSigning/sign.py" "$stage" "$credentials"
        else
            /usr/bin/python3 "$host/iOSSigning/sign.py" "$stage" "$credentials"
        fi
    fi
}

if [[ $mode == iap2 ]]; then
    [[ $# == 1 && "$1" == *.app && -d "$1/Contents" ]] || die '请指定待组装的 Mac App。'
    app=$(cd -- "$1" && pwd -P)
    python=$(build_python iap2)
    package_iap2 "$app" "$python"
    exit 0
fi

output=${1:-"$root/Build/Exports"}
mkdir -p -- "$output"
output=$(cd -- "$output" && pwd -P)
stage=$(mktemp -d "$output/.Everywhere-$mode-$(date +%Y%m%d-%H%M%S).XXXXXXXX")
if [[ $mode != mac ]]; then package_ios; fi
if [[ $mode != ios ]]; then package_mac; fi
name=${stage##*/}
release="$output/${name#.}"
mv "$stage" "$release"
stage=''
if [[ "$mode" == all && "$output" == "$root/Build/Exports" ]]; then
    latest="$root/Build/Everywhere"
    if [[ -e "$latest" && ! -L "$latest" ]]; then
        saved=$(mktemp -d "$output/Previous-Everywhere.XXXXXXXX")
        mv "$latest" "$saved/Everywhere"
    fi
    link_stage=$(mktemp -d "$root/Build/.latest.XXXXXXXX")
    ln -s "Exports/${name#.}" "$link_stage/Everywhere"
    /bin/mv -fh "$link_stage/Everywhere" "$latest"
fi
printf '已导出：%s\n' "$release"
