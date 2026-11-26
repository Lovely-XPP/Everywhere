#!/usr/bin/env bash
# 在项目构建目录准备 Qt 6.8.3 Android 工具链；传入 --release 后继续打包。
set -euo pipefail
umask 077
root=$(cd "$(dirname "$0")" && pwd)
cd "$root"
mode=${1:-}
case "$mode" in ""|--release) ;; *) echo "用法：./setup-android.sh [--release]" >&2; exit 2;; esac
tools_dir="$root/Build/AndroidEnv"
mkdir -p "$tools_dir"/{wheels,downloads,gradle}
if [[ -z ${ANDROID_SDK_ROOT:-} && -z ${ANDROID_HOME:-} ]]; then
    for candidate in "$tools_dir/sdk" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
        if [[ -d "$candidate/platforms" || -d "$candidate/cmdline-tools" ]]; then
            ANDROID_SDK_ROOT=$candidate
            break
        fi
    done
fi
export ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-"$tools_dir/sdk"}}
export ANDROID_HOME="$ANDROID_SDK_ROOT"
export GRADLE_USER_HOME="$tools_dir/gradle"
export PIP_CACHE_DIR="$tools_dir/pip-cache"
if [[ -x "$tools_dir/jdk/bin/javac" && -z ${JAVA_HOME:-} ]]; then
    export JAVA_HOME="$tools_dir/jdk"
elif [[ -z ${JAVA_HOME:-} && -x /usr/libexec/java_home ]]; then
    export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
fi
if [[ ! -x "${JAVA_HOME:-}/bin/javac" || $("$JAVA_HOME/bin/javac" -version 2>&1) != "javac 17."* ]]; then
    echo "需要 JDK 17，请设置 JAVA_HOME。" >&2; exit 1
fi
if [[ ! -x "$tools_dir/venv/bin/python" ]]; then
    python_bin=${ANDROID_HOST_PYTHON:-$(command -v python3.11 || command -v python3.10 || command -v python3)}
    "$python_bin" -c 'import sys; assert (3,10) <= sys.version_info[:2] <= (3,11), "请选择宿主 Python 3.10 或 3.11"'
    "$python_bin" -m venv "$tools_dir/venv"
fi
export VIRTUAL_ENV="$tools_dir/venv"
export PATH="$VIRTUAL_ENV/bin:$JAVA_HOME/bin:$ANDROID_SDK_ROOT/platform-tools:$PATH"
download() {
    local url=$1 output=$2 temp
    if [[ ! -s "$output" ]]; then
        temp=$(mktemp "${output}.XXXXXX")
        if ! curl --fail --location --retry 2 --connect-timeout 8 -o "$temp" "$url"; then
            rm -f "$temp"; return 1
        fi
        mv "$temp" "$output"
    fi
}
manager=$("$VIRTUAL_ENV/bin/python" qt/android_toolchain.py "$ANDROID_SDK_ROOT" --manager)
if [[ ! -x "$manager" ]]; then
    case "$(uname -s)" in Darwin) platform=mac;; Linux) platform=linux;; *) echo "需要 macOS 或 Linux。"; exit 1;; esac
    archive="commandlinetools-${platform}-11076708_latest.zip"
    download "https://dl.google.com/android/repository/$archive" "$tools_dir/downloads/$archive"
    if [[ "$platform" == mac ]]; then
        echo "7bc5c72ba0275c80a8f19684fb92793b83a6b5c94d4d179fc5988930282d7e64  $tools_dir/downloads/$archive" | shasum -a 256 -c -
    fi
    tmpdir=$(mktemp -d "$tools_dir/sdk-unpack.XXXXXX")
    trap 'rm -rf "$tmpdir"' EXIT
    unzip -q "$tools_dir/downloads/$archive" -d "$tmpdir"
    mkdir -p "$ANDROID_SDK_ROOT/cmdline-tools"
    mv "$tmpdir/cmdline-tools" "$ANDROID_SDK_ROOT/cmdline-tools/latest"
fi
"$VIRTUAL_ENV/bin/python" qt/android_toolchain.py "$ANDROID_SDK_ROOT"
"$VIRTUAL_ENV/bin/python" -m pip install "PySide6==6.8.3" "buildozer==1.5.0" "Cython<3" setuptools wheel
wheel_suffix="6.8.3-6.8.3-cp311-cp311-android_aarch64.whl"
for module in PySide6 shiboken6; do
    folder=$(echo "$module" | tr '[:upper:]' '[:lower:]')
    wheel="$module-$wheel_suffix"
    download "https://download.qt.io/official_releases/QtForPython/$folder/$wheel" "$tools_dir/wheels/$wheel"
    "$VIRTUAL_ENV/bin/python" -m zipfile -t "$tools_dir/wheels/$wheel"
done
if [[ "$mode" == --release ]]; then
    "$VIRTUAL_ENV/bin/python" package-android.py --release --sdk "$ANDROID_SDK_ROOT" \
        --pyside "$tools_dir/wheels/PySide6-$wheel_suffix" --shiboken "$tools_dir/wheels/shiboken6-$wheel_suffix"
fi
