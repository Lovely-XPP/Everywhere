"""平台相关的辅助程序、资源和凭据路径；冻结包从自身目录解析。"""
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SYSTEM = {'win32':'Windows', 'darwin':'macOS', 'linux':'Linux'}[sys.platform]


def helpers():
    if getattr(sys, 'frozen', False):
        return Path(sys.executable).parent
    return Path(os.environ.get('EVERYWHERE_HELPERS', ROOT / 'Build' / 'QtHelpers' / SYSTEM))


def binary(directory, name):
    return directory / (name + ('.exe' if sys.platform == 'win32' else ''))


def identity_dir():
    base = Path(sys.executable).parent
    roots = [base / 'asset/mfi', base.parent / 'Resources/asset/mfi', base]
    if not getattr(sys, 'frozen', False):
        roots.append(ROOT / 'asset/mfi')
    return next((p for p in roots if (p / 'certificate.p7b').is_file()), roots[0])


def user_key():
    if sys.platform == 'win32':
        base = Path(os.environ['LOCALAPPDATA'])
    elif sys.platform == 'darwin':
        base = Path.home() / 'Library/Application Support'
    else:
        base = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share'))
    return base / 'Everywhere/MFi/identity.pk8'
