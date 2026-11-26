"""回归 Release runner 中平台目录与 avdmanager 枚举结果不一致的情况。"""
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from qt.android_toolchain import select


class AndroidTargets(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.sdk = Path(temp.name)
        tools = self.sdk / "cmdline-tools/latest/bin"
        tools.mkdir(parents=True)
        for name in ("avdmanager", "sdkmanager"):
            (tools / name).touch(mode=0o755)
        for name in ("android-35", "android-36", "android-37.0"):
            platform = self.sdk / "platforms" / name
            platform.mkdir(parents=True)
            (platform / "android.jar").touch()
        env = patch.dict(os.environ, {"EVERYWHERE_ANDROID_API": ""})
        env.start()
        self.addCleanup(env.stop)

    @patch("qt.android_toolchain.subprocess.check_output")
    def test_runner_selects_highest_visible_installed_target(self, run):
        run.return_value = "".join(f"     API level: {level}\n" for level in (0, 34, 35, 36, 36))
        api, platform, _, _, missing = select(self.sdk)
        self.assertEqual((api, platform.name), ("36", "android-36"))
        self.assertFalse(any(name.startswith("platforms;") for name in missing))
        with patch.dict(os.environ, {"EVERYWHERE_ANDROID_API": "37"}):
            with self.assertRaisesRegex(SystemExit, "avdmanager 未列出 API 37"):
                select(self.sdk)
        run.return_value += "     API level: 37.0\n"
        self.assertEqual(select(self.sdk)[:2], ("37", self.sdk / "platforms/android-37.0"))
