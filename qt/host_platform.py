"""平台相关的辅助程序、资源和凭据路径；冻结包从自身目录解析。"""
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SYSTEM = {'win32':'Windows', 'darwin':'macOS', 'linux':'Linux'}[sys.platform]


def helpers():
    if getattr(sys, 'frozen', False):
        if sys.platform != 'darwin':
            directory = Path(sys._MEIPASS)
            if sys.platform == 'linux':
                # 单文件释放的 shell 脚本是数据文件。添加执行权限，并指向可移动的宿主。
                os.environ['EVERYWHERE_QT_EXECUTABLE'] = sys.executable
                for name in ('rfcomm', 'EverywhereGatt', 'EverywhereWorker'):
                    (directory / name).chmod(0o700)
            return directory
        return Path(sys.executable).parent
    return Path(os.environ.get('EVERYWHERE_HELPERS', ROOT / 'Build' / 'QtHelpers' / SYSTEM))


def binary(directory, name):
    return directory / (name + ('.exe' if sys.platform == 'win32' else ''))


def identity_dir():
    base = Path(sys.executable).parent
    roots = [base / 'asset/mfi', base.parent / 'Resources/asset/mfi', base]
    if getattr(sys, 'frozen', False):
        roots.insert(0, Path(sys._MEIPASS) / 'asset/mfi')
    else:
        roots.append(ROOT / 'asset/mfi')
    return next((p for p in roots if (p / 'certificate.p7b').is_file()), roots[0])


def check_bundled_helpers(verify_identity):
    """从单文件实际释放的位置启动辅助程序，无需连接设备。失败或超时会中止打包。"""
    directory = helpers()
    checks = [('rfcomm', '--self-test'), ('EverywhereGatt', '--self-test'),
              ('EverywhereWorker', '--self-test'), ('EverywhereWorker', 'connect', '--help')]
    if verify_identity:
        checks.append(('EverywhereWorker', '--verify-bundle'))
    for name, *args in checks:
        print(f"Checking {name} {' '.join(args)}", flush=True)
        result = subprocess.run([binary(directory, name), *args], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45,
                                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
        if result.returncode:
            raise RuntimeError(f'{name} exited with {result.returncode}: ' +
                               result.stdout.decode('utf-8', 'replace'))


def user_key():
    if sys.platform == 'win32':
        base = Path(os.environ['LOCALAPPDATA'])
    elif sys.platform == 'darwin':
        base = Path.home() / 'Library/Application Support'
    else:
        base = Path(os.environ.get('XDG_DATA_HOME', Path.home() / '.local/share'))
    return base / 'Everywhere/MFi/identity.pk8'
