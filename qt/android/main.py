"""Everywhere Android 前台配件控制台。设备查询和 RFCOMM 会话在独立线程运行。"""
import asyncio
import sys
import threading

from PySide6 import QtCore as C, QtWidgets as W

from appearance import style
from mapview import MapView
from session import local_address, paired_devices, run_session, target_command


class Scan(C.QThread):
    result = C.Signal(list, str, str)

    def run(self):
        try:
            devices, address = paired_devices()
            self.result.emit(devices, address, "")
        except Exception as error:
            self.result.emit([], "", str(error))


class Session(C.QThread):
    changed = C.Signal(dict)

    def __init__(self, device, address):
        super().__init__()
        self.device, self.address = device, address
        self.lock = threading.Lock()
        self.loop = self.task = self.pending = None
        self.stopping = False
        self.detail = ""

    def submit(self, coords):
        with self.lock:
            if not self.stopping:
                self.pending = target_command(*coords)

    def take_update(self):
        with self.lock:
            value, self.pending = self.pending, None
            return value

    def stop(self):
        with self.lock:
            if self.stopping:
                return
            self.stopping = True
            if self.task is not None:
                self.loop.call_soon_threadsafe(self.task.cancel)

    def publish(self, **event):
        if event["event"] != "message":
            self.changed.emit(event)

    async def serve(self):
        with self.lock:
            if self.stopping:
                return
            self.loop, self.task = asyncio.get_running_loop(), asyncio.current_task()
        try:
            await run_session(self.device, self.address, self.publish, self.take_update)
        finally:
            with self.lock:
                self.loop = self.task = None

    def run(self):
        try:
            asyncio.run(self.serve())
        except asyncio.CancelledError:
            pass
        except Exception as error:
            self.detail = str(error) or type(error).__name__


class Console(W.QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Everywhere")
        self.setObjectName("inspector")
        self.session = self.scan = self.coords = None
        self.identified = self.authenticated = False
        self.closing = False
        self.settings = C.QSettings("Everywhere", "Android")
        layout = W.QVBoxLayout(self)
        title = W.QLabel("iPhone 配件定位")
        title.setObjectName("modeTitle")
        layout.addWidget(title)
        self.devices = W.QComboBox()
        self.refresh = self.button("刷新设备", self.discover)
        row = W.QHBoxLayout()
        row.addWidget(self.devices, 1)
        row.addWidget(self.refresh)
        layout.addLayout(row)
        self.address = W.QLineEdit(str(self.settings.value("localAddress", "")))
        self.address.setPlaceholderText("安卓本机蓝牙地址（见关于手机 → 状态）")
        layout.addWidget(self.address)
        self.connect_button = self.button("连接所选 iPhone", self.connect_device)
        layout.addWidget(self.connect_button)
        self.map = MapView()
        self.map.setMinimumSize(180, 140)
        self.map.picked.connect(self.pick)
        layout.addWidget(self.map, 1)
        row = W.QHBoxLayout()
        self.target = W.QLabel("请在地图上选点")
        row.addWidget(self.target, 1)
        for label, step in (("−", -1), ("+", 1)):
            row.addWidget(self.button(label, lambda checked=False, s=step: self.map.zoom(s)))
        layout.addLayout(row)
        self.status = W.QLabel("先在 Android 系统蓝牙设置中配对 iPhone，然后刷新设备。")
        self.status.setWordWrap(True)
        layout.addWidget(self.status)
        row = W.QHBoxLayout()
        self.send = self.button("发送地图选点", self.send_point, "primary")
        self.end = self.button("结束 / 恢复定位", self.end_session)
        row.addWidget(self.send)
        row.addWidget(self.end)
        layout.addLayout(row)
        style(self)
        self.devices.currentIndexChanged.connect(self.controls)
        self.controls()

    @staticmethod
    def button(text, action, name="secondary"):
        button = W.QPushButton(text)
        button.setObjectName(name)
        button.clicked.connect(action)
        return button

    def controls(self):
        idle = self.session is None and self.scan is None
        self.devices.setEnabled(idle)
        self.address.setEnabled(idle)
        self.refresh.setEnabled(idle)
        self.connect_button.setEnabled(idle and self.devices.currentData() is not None)
        active = self.session is not None and not self.session.stopping
        self.end.setEnabled(active)
        self.send.setEnabled(active and self.identified and self.authenticated and self.coords is not None)

    def discover(self):
        if self.scan or self.session:
            return
        from jnius import autoclass
        # API 28–30 查询已配对设备只需安装时授予的普通蓝牙权限。
        if autoclass("android.os.Build$VERSION").SDK_INT < 31:
            self.start_scan()
            return
        permission = C.QBluetoothPermission()
        permission.setCommunicationModes(C.QBluetoothPermission.CommunicationMode.Access)
        app = W.QApplication.instance()
        if app.checkPermission(permission) == C.Qt.PermissionStatus.Granted:
            self.start_scan()
        else:
            app.requestPermission(permission, self, self.after_permission)

    def after_permission(self, permission=None):
        request = C.QBluetoothPermission()
        request.setCommunicationModes(C.QBluetoothPermission.CommunicationMode.Access)
        if W.QApplication.instance().checkPermission(request) == C.Qt.PermissionStatus.Granted:
            self.start_scan()
        else:
            self.status.setText("请在系统的应用权限中允许访问附近设备，然后刷新。")

    def start_scan(self):
        if self.scan or self.session or self.closing:
            return
        self.scan = Scan()
        self.scan.result.connect(self.show_devices)
        self.scan.finished.connect(self.scan_finished)
        self.controls()
        self.scan.start()

    def show_devices(self, devices, local, error):
        previous = self.devices.currentData()
        self.devices.clear()
        for name, address in devices:
            self.devices.addItem(f"{name} · {address}", address)
        if previous and self.devices.findData(previous) >= 0:
            self.devices.setCurrentIndex(self.devices.findData(previous))
        if local:
            self.address.setText(local)
        self.status.setText(error or ("请选择已配对的 iPhone。" if devices else "没有已配对设备。"))

    def scan_finished(self):
        self.scan.deleteLater()
        self.scan = None
        self.controls()
        if self.closing:
            self.close()

    def pick(self, lat, lon):
        self.coords = (lat, lon)
        self.map.choose(self.coords, center=False)
        self.target.setText(f"{lat:.6f}, {lon:.6f}")
        self.controls()

    def connect_device(self):
        value = self.address.text().strip()
        try:
            local_address(value)
        except ValueError:
            self.status.setText("请输入本机的六组十六进制蓝牙地址，例如从 Android 系统状态页抄录。")
            return
        self.settings.setValue("localAddress", value)
        self.session = Session(self.devices.currentData(), value)
        self.session.changed.connect(self.show_event)
        self.session.finished.connect(self.ended)
        self.status.setText("正在查询 iPhone 的 iAP2 服务并连接…")
        self.controls()
        self.session.start()

    def show_event(self, event):
        if self.sender() is not self.session or self.session.stopping:
            return
        kind = event["event"]
        if kind == "identification_accepted":
            self.identified = True
        elif kind == "authentication_succeeded":
            self.authenticated = True
        messages = {"rfcomm_connected": "RFCOMM 已连接，正在检测 iAP2。",
                    "link_ready": "iAP2 已握手，等待配件识别和认证。",
                    "target_updated": "选点已提交，等待 iPhone 订阅和链路回执。",
                    "location_requested": "iPhone 已更新定位订阅。",
                    "location_stopped": "iPhone 已暂停定位订阅。"}
        if kind in ("identification_accepted", "authentication_succeeded"):
            self.status.setText("识别和认证已通过，可以发送选点。" if self.identified and self.authenticated
                                else "正在完成配件识别和认证…")
        elif kind == "location_link_acknowledged":
            self.status.setText(f"位置包已获链路回执（{event['count']}）。请在 iPhone 检查系统位置。")
        elif kind in messages:
            self.status.setText(messages[kind])
        self.controls()

    def confirm(self, title):
        box = W.QMessageBox(self)
        box.setWindowTitle(title)
        box.setText("发送或恢复后，请在 iPhone 设置 → 隐私与安全性 → 定位服务中关闭再打开定位服务。"
                    "如果仍未生效，请重启手机并核对定位。")
        ok = box.addButton("我已知晓", W.QMessageBox.ButtonRole.AcceptRole)
        box.addButton("取消", W.QMessageBox.ButtonRole.RejectRole)
        box.exec()
        return box.clickedButton() == ok

    def send_point(self):
        session, coords = self.session, self.coords
        if self.confirm("发送地图选点") and self.session is session and session and self.send.isEnabled():
            session.submit(coords)

    def end_session(self):
        session = self.session
        if self.confirm("结束配件会话") and self.session is session and session:
            session.stop()
            self.controls()

    def ended(self):
        error = self.session.detail
        self.session.deleteLater()
        self.session = None
        self.identified = self.authenticated = False
        self.status.setText(f"会话中断，设备状态未知：{error}" if error else
                            "配件连接已结束，请在 iPhone 确认真实定位恢复。")
        self.controls()
        if self.closing:
            self.close()

    def closeEvent(self, event):
        if self.session or self.scan:
            self.closing = True
            if self.session:
                self.session.stop()
            event.ignore()
        else:
            event.accept()


if __name__ == "__main__":
    app = W.QApplication(sys.argv)
    window = Console()
    window.showMaximized()
    sys.exit(app.exec())
