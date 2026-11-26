"""从本次构建的代码提取版本和发布说明，给五个安装包命名，输出对应 Git 标签。"""

from pathlib import Path
import plistlib
import re
import runpy
import shutil
import sys


def prepare(packages: Path, output: Path) -> str:
    """检查 Swift、Qt 版本、CHANGELOG 条目及五个产物；任何缺失或歧义都阻止发布。"""
    version = runpy.run_path("qt/app_version.py")["VERSION"]
    with Path("swift/Host/MacApp/Info.plist").open("rb") as source:
        mac_version = plistlib.load(source)["CFBundleShortVersionString"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or version != mac_version:
        raise ValueError(f"Inconsistent package versions: Qt {version}, Swift {mac_version}")

    changelog = Path("CHANGELOG").read_text(encoding="utf-8")
    headings = list(re.finditer(r"^虚拟定位 App (\d+\.\d+\.\d+)\b[^\r\n]*$", changelog, re.M))
    sections = [
        changelog[heading.end():headings[i + 1].start() if i + 1 < len(headings) else len(changelog)].strip()
        for i, heading in enumerate(headings) if heading[1] == version
    ]
    if len(sections) != 1 or not sections[0]:
        raise ValueError(f"Expected one non-empty CHANGELOG section for {version}")

    # 同一版本的 CI 产物目录、源文件名和公开附件名。
    archives = [
        ("package-mac-x64", "Everywhere-macOS.zip", "mac-x64.zip"),
        ("package-mac-arm64", "Everywhere-macOS.zip", "mac-arm64.zip"),
        ("package-linux-x64", f"EverywhereQt-Linux-x86_64-{version}-*.tar.gz", "linux-x64.tar.gz"),
        ("package-windows-x64", f"Everywhere-Windows-x64-{version}-*.zip", "windows-x64.zip"),
        ("package-apk", f"Everywhere-{version}-arm64-release.apk", "android-arm64.apk"),
    ]
    for artifact, pattern, suffix in archives:
        directory = packages / artifact
        matches = list(directory.rglob(pattern))
        if len(matches) != 1 or not matches[0].is_file() or not matches[0].stat().st_size:
            raise ValueError(f"Expected one non-empty {pattern} in {directory}")
        shutil.move(matches[0], output / f"Everywhere-{version}-{suffix}")
    (output / "notes.md").write_text(sections[0] + "\n", encoding="utf-8")
    return f"v{version}"


if __name__ == "__main__":
    print(prepare(Path(sys.argv[1]), Path(sys.argv[2])))
