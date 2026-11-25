"""签署导出暂存区内的 Everywhere IPA；只在签名和复验成功后发布。"""
import datetime
import fnmatch
import getpass
import hashlib
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


def run(*args, data=None):
    return subprocess.run(args, input=data, stdout=subprocess.PIPE, check=True).stdout


def sign(stage, folder):
    p12, = folder.glob("*.p12")
    profile, = folder.glob("*.mobileprovision")
    password = os.environ.pop("EVERYWHERE_IOS_P12_PASSWORD", None)
    local_password = folder / "p12-password"
    if password is None and local_password.is_file():
        password = local_password.read_text(encoding="utf-8").rstrip("\r\n")
    if password is None:
        if not sys.stdin.isatty():
            raise ValueError("非交互导出需提供 EVERYWHERE_IOS_P12_PASSWORD。")
        password = getpass.getpass("iOS 签名证书密码：")
    openssl = "/usr/bin/openssl"

    def pkcs12(*flags):
        return run(openssl, "pkcs12", "-in", p12, "-passin", "stdin", *flags,
                   data=(password + "\n").encode())

    leaf = run(openssl, "x509", "-outform", "DER", data=pkcs12("-clcerts", "-nokeys"))
    profile_data = plistlib.loads(run(openssl, "smime", "-verify", "-inform", "der",
                                     "-in", profile, "-noverify"))
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    if not profile_data["CreationDate"] <= now < profile_data["ExpirationDate"]:
        raise ValueError("描述文件不在有效期内。")
    if leaf not in profile_data["DeveloperCertificates"]:
        raise ValueError("签名证书与描述文件不匹配。")
    run(openssl, "x509", "-inform", "DER", "-checkend", "0", "-noout", data=leaf)
    with tempfile.TemporaryDirectory() as temporary:
        work = Path(temporary)
        archive = stage / "Everywhere.ipa"
        run("/usr/bin/ditto", "-x", "-k", archive, work)
        app = work / "Payload/Everywhere.app"
        if any(p.suffix in {".appex", ".framework", ".dylib", ".app"} for p in app.rglob("*")):
            raise ValueError("该导出包含嵌套可执行代码，需分别签名。")
        info_path = app / "Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        allowed = profile_data["Entitlements"]
        prefix, pattern = allowed["application-identifier"].split(".", 1)
        bundle = info["CFBundleIdentifier"] if "*" in pattern else pattern
        if not fnmatch.fnmatchcase(bundle, pattern):
            raise ValueError("描述文件与应用标识不兼容。")
        full_id = prefix + "." + bundle
        if not any(fnmatch.fnmatchcase(full_id, rule) for rule in allowed.get("keychain-access-groups", [])):
            raise ValueError("描述文件未授权该钥匙串组。")
        requested = Path(__file__).resolve().parents[2] / "Apps/Mobile/Mobile/Diagnostics/WiFi.entitlements"
        entitlements = plistlib.loads(requested.read_bytes())
        if any(allowed.get(k) != v for k, v in entitlements.items()):
            raise ValueError("描述文件未授权 App 请求的全部权限。")
        entitlements.update({"application-identifier": full_id, "keychain-access-groups": [full_id],
                             "com.apple.developer.team-identifier": profile_data["TeamIdentifier"][0]})
        if allowed.get("get-task-allow"):
            entitlements["get-task-allow"] = True
        info["CFBundleIdentifier"] = bundle
        info_path.write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        shutil.copyfile(profile, app / "embedded.mobileprovision")
        xml = plistlib.dumps(entitlements)
        (work / "ent.blob").write_bytes(struct.pack(">II", 0xfade7171, len(xml) + 8) + xml)
        (work / "leaf.cer").write_bytes(leaf)
        helper = work / "sign"
        run("/usr/bin/xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-framework", "Foundation",
            "-framework", "Security", Path(__file__).with_name("sign.m"), "-o", helper)
        key = run(openssl, "rsa", "-outform", "DER", data=pkcs12("-nocerts", "-nodes"))
        run(helper, work / "leaf.cer", work / "ent.blob", app, data=key)
        signed = work / "signed.ipa"
        subprocess.run(["/usr/bin/zip", "-qry", signed, "Payload"], cwd=work, check=True)
        checked = work / "checked"
        run("/usr/bin/ditto", "-x", "-k", signed, checked)
        requirement = 'certificate leaf = H"' + hashlib.sha1(leaf).hexdigest() + '"'
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", "-R=" + requirement, checked / "Payload/Everywhere.app")
        shutil.copyfile(archive, stage / "Everywhere-unsigned.ipa")
        shutil.copyfile(signed, archive)


if __name__ == "__main__":
    sign(Path(sys.argv[1]), Path(sys.argv[2]))
