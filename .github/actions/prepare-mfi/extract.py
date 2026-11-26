"""从 Release ZIP 中提取同一目录下的 MFi 证书和私钥，供三个桌面打包脚本使用。"""

from pathlib import Path, PurePosixPath
import sys
from zipfile import ZipFile


def extract_identity(archive: Path, destination: Path) -> None:
    """仅写入指定文件。证书或私钥缺失、重复、为空或来自不同目录时终止构建。"""
    names = ("certificate.p7b", "identity.pk8")
    members = {}
    with ZipFile(archive) as source:
        for entry in source.infolist():
            path = PurePosixPath(entry.filename)
            if entry.is_dir() or "__MACOSX" in path.parts or path.name not in names:
                continue
            if path.name in members or entry.file_size == 0:
                raise ValueError(f"Duplicate or empty release asset: {path.name}")
            members[path.name] = entry
        if set(members) != set(names):
            raise ValueError("asset.zip must contain certificate.p7b and identity.pk8")
        if len({PurePosixPath(entry.filename).parent for entry in members.values()}) != 1:
            raise ValueError("The accessory certificate and key must share a directory")
        # 先读取并校验两项的 ZIP CRC，再写到固定路径，避免展开其他签名材料。
        files = {name: source.read(members[name]) for name in names}

    destination.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (destination / name).write_bytes(data)


if __name__ == "__main__":
    extract_identity(Path(sys.argv[1]), Path("asset/mfi"))
