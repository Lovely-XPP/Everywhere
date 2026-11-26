"""在当前 macOS 或 Linux 构建可独立运行的 Qt 目录包，验证后发布。"""
import argparse
import os
from pathlib import Path
import platform
import plistlib
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid

from app_version import VERSION

ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / 'qt'
MODERN = ROOT / 'swift/Host/ModernBackend'
IAP2 = ROOT / 'swift/Host/IAP2Client'
MAC = sys.platform == 'darwin'
SYSTEM = 'macOS' if MAC else 'Linux'
APP = 'EverywhereQt'


def run(*args, **kwargs):
    return subprocess.run(list(map(str,args)),check=True,**kwargs)


def wrapper(path, invocation):
    path.write_text('#!/bin/sh\nexec '+invocation+' "$@"\n')
    path.chmod(0o755)


def helpers(dest, scratch, python, frozen):
    dest.mkdir(parents=True,exist_ok=True)
    if MAC:
        plist=IAP2/'BridgeInfo.plist'
        run('xcrun','clang','-mmacosx-version-min=14.0','-fobjc-arc','-framework','Foundation','-framework','IOBluetooth',
            '-Xlinker','-sectcreate','-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',plist,
            IAP2/'native/bluetooth_bridge.m','-o',dest/'rfcomm')
        opts=['--package-path',ROOT/'swift','--scratch-path',scratch/'swift','--cache-path',scratch/'cache',
              '--disable-sandbox','-c','release']
        # Select the original SwiftPM engine when the installed toolchain offers both.
        help_text=run('xcrun','swift','build','--help',capture_output=True,text=True).stdout
        if '--build-system' in help_text and 'native ' in help_text: opts+=['--build-system','native']
        run('xcrun','swift','build',*opts,'--product','QtBluetoothBridge','-Xlinker','-sectcreate',
            '-Xlinker','__TEXT','-Xlinker','__info_plist','-Xlinker',plist)
        products=run('xcrun','swift','build',*opts,'--show-bin-path',capture_output=True,text=True).stdout.strip()
        shutil.copy2(Path(products)/'QtBluetoothBridge',dest/'QtBluetoothBridge')
        run(dest/'QtBluetoothBridge','--self-test')
    if frozen:
        gui='"$(dirname "$0")/EverywhereQt"'
        if MAC:
            run('xcrun','clang','-mmacosx-version-min=14.0','-O2', SRC/'native/mac_worker.c','-o',dest/'EverywhereWorker')
        else:
            wrapper(dest/'EverywhereWorker',gui+' --qt-worker')
            wrapper(dest/'rfcomm',gui+' --linux-rfcomm')
            wrapper(dest/'EverywhereGatt',gui+' --linux-gatt')
    else:
        exe = shlex.quote(str(python))
        for binary,script in [('EverywhereWorker','worker.py')]+([] if MAC else [('rfcomm','linux_rfcomm.py'),('EverywhereGatt','linux_gatt.py')]):
            wrapper(dest/binary,exe+' '+shlex.quote(str(SRC/script)))


def build(args, scratch, python):
    run(python,'-c','import sys,ssl; assert sys.version_info[:2]==(3,13) and ssl.HAS_PSK, "Python 3.13 with TLS-PSK required"')
    if args.helpers_only:
        out=ROOT/'Build/QtHelpers'/SYSTEM
        helpers(out,scratch,python,False)
        print(out)
        return
    out=Path(args.output_dir).resolve()
    out.mkdir(parents=True,exist_ok=True)
    stage=scratch/'dist'
    identity=ROOT/'asset/mfi'
    identity_files = []
    if os.environ.get('EVERYWHERE_BUNDLE_MFI_IDENTITY') != '0':
        identity_files.append('certificate.p7b')
        if not args.without_key:
            identity_files.append('identity.pk8')
    for name in identity_files:
        if not (identity/name).is_file(): raise FileNotFoundError(identity/name)
    run(python,'-m','pip','check')
    qt_env={**os.environ,'QT_QPA_PLATFORM':'offscreen','PYTHONDONTWRITEBYTECODE':'1'}
    run(python,'-m','unittest','discover','-s',SRC/'tests',env=qt_env)
    options=['--windowed','--icon',ROOT/'swift/Host/MacApp/VirtualLocation.icns',
             '--osx-bundle-identifier','com.virtuallocation.everywhere.qt','--hidden-import','keyring.backends.macOS'] if MAC else [
             '--hidden-import','keyring.backends.SecretService','--collect-submodules','bleak.backends.bluezdbus']
    run(python,'-m','PyInstaller','--noconfirm','--noupx','--onedir','--name',APP,'--distpath',stage,
        '--workpath',scratch/'work','--specpath',scratch,'--paths',MODERN,'--paths',IAP2/'src',
        '--recursive-copy-metadata','pymobiledevice3','--collect-data','pymobiledevice3','--collect-data','developer_disk_image',
        '--collect-submodules','pytcp','--copy-metadata','keyring','--exclude-module','pytest',
        '--exclude-module','IPython',*options,SRC/'app.py')
    product=stage/(APP+'.app' if MAC else APP)
    bin_dir=product/'Contents/MacOS' if MAC else product
    resources=product/'Contents/Resources' if MAC else product
    helpers(bin_dir,scratch,python,True)
    dest=resources/'asset/mfi'
    dest.mkdir(parents=True)
    for name in identity_files:
        shutil.copy2(identity/name,dest)
    license_dir=resources/'licenses/accessory_location'
    license_dir.mkdir(parents=True)
    for file in ('NOTICE','LICENSE'):
        shutil.copy2(IAP2/file,license_dir/file)
    # Include the corresponding buildable source. Only named source trees are archived.
    source_paths = ['qt', 'swift/Host/IAP2Client', 'swift/Host/ModernBackend',
                    'swift/Package.swift', 'swift/Sources', 'swift/Apps/Mobile/Mobile',
                    'swift/Tests', 'swift/Host/MacApp/VirtualLocation.icns',
                    'package-python-macos.sh', 'package-python-linux.sh', 'package-windows.ps1']
    def source_only(member):
        if any(part in ('__pycache__','.DS_Store') for part in Path(member.name).parts):
            return None
        return member
    with tarfile.open(license_dir/'source.tar.gz','w:gz') as files:
        for path in source_paths:
            files.add(ROOT/path, arcname=path, filter=source_only)
    if MAC:
        info=product/'Contents/Info.plist'
        metadata=plistlib.loads(info.read_bytes())
        metadata.update(CFBundleShortVersionString=VERSION, CFBundleVersion='2',
                        NSBluetoothAlwaysUsageDescription='连接所选 iPhone 以传输选点，或向手机提供蓝牙状态。',
                        NSLocalNetworkUsageDescription='发现和连接已配对的局域网 iPhone。',
                        NSBonjourServices=['_apple-mobdev2._tcp','_vloc-remote._tcp'],LSMinimumSystemVersion='14.0')
        info.write_bytes(plistlib.dumps(metadata))
        for binary in ('rfcomm','QtBluetoothBridge','EverywhereWorker'):
            run('codesign','--force','--sign','-',bin_dir/binary)
        run('codesign','--force','--sign','-',product)
        run('codesign','--verify','--deep','--strict',product)
    else:
        run(bin_dir/'rfcomm','--self-test')
        run(bin_dir/'EverywhereGatt','--self-test')
    run(bin_dir/'EverywhereWorker','--self-test')
    run(bin_dir/'EverywhereWorker','connect','--help')
    if 'identity.pk8' in identity_files: run(bin_dir/'EverywhereWorker','--verify-bundle')
    run(bin_dir/APP,'--smoke-test',env=qt_env,timeout=90)
    name=f'{APP}-{SYSTEM}-{platform.machine()}-{VERSION}-{time.strftime("%Y%m%d-%H%M%S")}-{uuid.uuid4().hex[:6]}'
    archive=scratch/(name+('.zip' if MAC else '.tar.gz'))
    if MAC:
        run('ditto','-c','-k','--keepParent',product,archive)
    else:
        with tarfile.open(archive,'w:gz') as tar: tar.add(product,arcname=APP)
    if 'identity.pk8' in identity_files:
        archive.chmod(0o600)
    shutil.move(str(archive),out/archive.name)
    print(out/archive.name,flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform',choices=['macOS','Linux'],required=True)
    parser.add_argument('--output-dir',default=ROOT/'Build/Exports')
    parser.add_argument('--without-key',action='store_true',help='仅包含配件证书')
    parser.add_argument('--prepared-python',type=Path,help='已有完整构建依赖的 Python 3.13 解释器')
    parser.add_argument('--helpers-only',action='store_true',help='仅准备从源码启动时使用的辅助程序')
    args=parser.parse_args()
    if sys.platform not in ('darwin','linux') or args.platform != SYSTEM: parser.error('请在目标操作系统本机运行')
    python=args.prepared_python
    if python is None:
        interpreter=os.environ.get('EVERYWHERE_QT_PYTHON') or shutil.which('python3.13')
        if not interpreter: parser.error('需要 Python 3.13；可通过 EVERYWHERE_QT_PYTHON 指定解释器')
        venv=ROOT/'Build'/('Qt-Python-'+SYSTEM)
        python=venv/'bin/python'
        if not python.exists(): run(interpreter,'-m','venv',venv)
        run(python,'-m','pip','install','-r',MODERN/'requirements.txt','-r',SRC/'requirements.txt')
    python=python.absolute()
    with tempfile.TemporaryDirectory(prefix='everywhere-qt-') as directory:
        build(args,Path(directory),python)


if __name__=='__main__':
    main()
