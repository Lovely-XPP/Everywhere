"""Everywhere Android 前台配件控制台。设备查询和 RFCOMM 会话在独立线程运行。"""
import asyncio
import json
import sys
import threading

from PySide6 import QtCore as C, QtWidgets as W

from appearance import Destination, Dropdown, ElidingLabel, Symbol, icon, label, style
from console_ui import group, segment
from core import point
from dialogs import text_prompt
from mapview import MapView
from place_browser import PlaceBrowser
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
        self.last_query = 0.0
        self.settings = C.QSettings("Everywhere", "Android")
        layout = W.QVBoxLayout(self)
        layout.setContentsMargins(12, 12, 12, 12)
        layout.setSpacing(8)
        header = W.QHBoxLayout()
        header.addWidget(Symbol('location', 36, 'white', True))
        headings = W.QVBoxLayout()
        headings.setSpacing(0)
        headings.addWidget(label('Everywhere', 'modeTitle'))
        headings.addWidget(label('iPhone 配件定位 · Android', 'caption'))
        header.addLayout(headings, 1)
        self.connection_state = label('未连接', 'caption')
        header.addWidget(self.connection_state)
        layout.addLayout(header)
        self.workspace = W.QBoxLayout(W.QBoxLayout.TopToBottom)
        self.workspace.setSpacing(8)
        layout.addLayout(self.workspace, 1)
        map_panel = W.QFrame()
        map_panel.setObjectName('panel')
        map_box = W.QVBoxLayout(map_panel)
        map_box.setContentsMargins(6, 6, 6, 6)
        map_box.setSpacing(6)
        self.map = MapView(refresh_window=True)
        self.map.setMinimumSize(160, 90)
        self.map.picked.connect(self.pick)
        self.map.favorite_picked.connect(lambda name, lat, lon: self.draft((lat, lon), name=name))
        map_tools = W.QHBoxLayout()
        map_tools.addWidget(self.button("搜索地点", lambda: self.places('search'), symbol='search'), 1)
        map_tools.addWidget(self.button("刷新", self.map.refresh_tiles, symbol='refresh'))
        for text, step in (("−", -1), ("+", 1)):
            map_tools.addWidget(self.button(text, lambda checked=False, s=step: self.map.zoom(s)))
        map_box.addLayout(map_tools)
        map_box.addWidget(self.map, 1)
        self.workspace.addWidget(map_panel, 1)
        self.inspector = W.QWidget()
        inspector_box = W.QVBoxLayout(self.inspector)
        inspector_box.setContentsMargins(0, 0, 0, 0)
        inspector_box.setSpacing(6)
        self.tabs = segment(inspector_box, [('地点', 'map', 'place'), ('设备', 'device', 'devices')])
        self.pages = W.QStackedWidget()
        inspector_box.addWidget(self.pages, 1)
        self.workspace.addWidget(self.inspector)
        place_page = W.QWidget()
        place_box = W.QVBoxLayout(place_page)
        place_box.setContentsMargins(0, 0, 0, 0)
        place_box.setSpacing(8)
        destination = Destination()
        destination.setObjectName('destination')
        destination_box = W.QVBoxLayout(destination)
        self.target = ElidingLabel('destinationTitle')
        self.target.setText('选择目的地')
        self.target_coords = label("请在地图上选点或输入坐标", '', True)
        destination_box.addWidget(self.target)
        destination_box.addWidget(self.target_coords)
        destination_box.setContentsMargins(16, 12, 16, 12)
        place_box.addWidget(destination)
        _, coords_box, _ = group(place_box, '坐标 · WGS 84')
        fields = W.QHBoxLayout()
        for attr, title in (('lat', '纬度'), ('lon', '经度')):
            column = W.QVBoxLayout()
            column.addWidget(label(title, 'caption'))
            field = W.QLineEdit()
            field.setPlaceholderText(title)
            field.setAccessibleName(title)
            field.setInputMethodHints(C.Qt.ImhFormattedNumbersOnly)
            field.setMinimumHeight(42)
            field.returnPressed.connect(self.show_entry)
            field.textEdited.connect(self.coordinate_edited)
            setattr(self, attr, field)
            column.addWidget(field)
            fields.addLayout(column, 1)
        coords_box.addLayout(fields)
        coords_box.addWidget(self.button('在地图上查看草稿', self.show_entry))
        shortcuts = W.QHBoxLayout()
        shortcuts.addWidget(self.button('收藏地点', self.save_place, symbol='bookmark'))
        shortcuts.addWidget(self.button('地点簿', lambda: self.places('favorites'), symbol='map'))
        place_box.addLayout(shortcuts)
        self.pages.addWidget(self.scroll_page(place_page))
        device_page = W.QWidget()
        device_box = W.QVBoxLayout(device_page)
        device_box.setContentsMargins(0, 0, 0, 0)
        _, device_controls, _ = group(device_box, '目标设备')
        self.devices = Dropdown('选择已配对设备', 'phone')
        self.refresh = self.button("刷新设备", self.discover)
        row = W.QHBoxLayout()
        row.addWidget(self.devices, 1)
        row.addWidget(self.refresh)
        device_controls.addLayout(row)
        self.address = W.QLineEdit(str(self.settings.value("localAddress", "")))
        self.address.setPlaceholderText("00:00:00:00:00:00")
        self.address.setAccessibleName('安卓本机蓝牙地址')
        self.address.setMinimumHeight(42)
        device_controls.addWidget(label('本机蓝牙地址', 'caption'))
        self.auto_address = self.button("自动获取", self.discover)
        address_row = W.QHBoxLayout()
        address_row.addWidget(self.address, 1)
        address_row.addWidget(self.auto_address)
        device_controls.addLayout(address_row)
        self.connect_button = self.button("连接所选 iPhone", self.connect_device, 'primary')
        device_controls.addWidget(self.connect_button)
        self.pages.addWidget(self.scroll_page(device_page))
        self.tabs.currentChanged.connect(self.pages.setCurrentIndex)
        self.refresh_places()
        footer = W.QFrame()
        footer.setObjectName('footer')
        footer_box = W.QVBoxLayout(footer)
        footer_box.setContentsMargins(10, 8, 10, 8)
        footer_box.setSpacing(6)
        self.status = label("先在 Android 系统蓝牙设置中配对 iPhone，然后刷新设备。", 'muted', True)
        footer_box.addWidget(self.status)
        row = W.QHBoxLayout()
        self.send = self.button("发送地图选点", self.send_point, "primary")
        self.end = self.button("结束 / 恢复定位", self.end_session)
        row.addWidget(self.send, 3)
        row.addWidget(self.end, 2)
        footer_box.addLayout(row)
        layout.addWidget(footer)
        style(self)
        self.devices.currentIndexChanged.connect(self.controls)
        self.controls()
        C.QTimer.singleShot(0, self.discover)

    @staticmethod
    def scroll_page(page):
        """让地点及设备面板在小屏幕和软键盘展开时仍可滚动。"""
        area = W.QScrollArea()
        area.setWidgetResizable(True)
        area.setFrameShape(W.QFrame.NoFrame)
        area.setHorizontalScrollBarPolicy(C.Qt.ScrollBarAlwaysOff)
        area.setWidget(page)
        return area

    def resizeEvent(self, event):
        super().resizeEvent(event)
        if hasattr(self, 'inspector'):
            wide = self.width() >= 660 and self.width() > self.height()
            self.workspace.setDirection(W.QBoxLayout.LeftToRight if wide else W.QBoxLayout.TopToBottom)
            if wide:
                self.inspector.setMinimumHeight(0)
                self.inspector.setMaximumHeight(16777215)
                self.inspector.setFixedWidth(min(360, self.width() // 2))
            else:
                self.inspector.setMinimumWidth(0)
                self.inspector.setMaximumWidth(16777215)
                self.inspector.setFixedHeight(max(115, min(340, self.height() * 43 // 100)))

    @staticmethod
    def button(text, action, name="secondary", symbol=None):
        button = W.QPushButton(text)
        button.setObjectName(name)
        button.setMinimumHeight(42)
        if symbol:
            button.setIcon(icon(symbol))
        button.clicked.connect(action)
        return button

    def controls(self):
        idle = self.session is None and self.scan is None
        self.devices.setEnabled(idle)
        self.address.setEnabled(idle)
        self.auto_address.setEnabled(idle)
        self.refresh.setEnabled(idle)
        self.connect_button.setEnabled(idle and self.devices.currentData() is not None)
        active = self.session is not None and not self.session.stopping
        self.connection_state.setText('已连接' if active and self.authenticated else
                                      '连接中' if active else '查询中' if self.scan else '未连接')
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
            self.devices.addDevice(name, address, name)
        if previous and self.devices.findData(previous) >= 0:
            self.devices.setCurrentIndex(self.devices.findData(previous))
        if local:
            self.address.setText(local)
        device_status = "请选择已配对的 iPhone。" if devices else "没有已配对设备。"
        address_status = ("已自动获取本机蓝牙地址。" if local else
                          "系统未提供本机蓝牙地址，请在系统状态页查看并手动填写。")
        self.status.setText(error or f"{address_status}{device_status}")

    def scan_finished(self):
        self.scan.deleteLater()
        self.scan = None
        self.controls()
        if self.closing:
            self.close()

    def pick(self, lat, lon):
        self.draft((lat, lon), center=False)

    def draft(self, coords, center=True, name=None):
        """更新地图草稿和坐标编辑框，不执行设备命令。"""
        self.coords = lat, lon = point(*coords)
        self.lat.setText(f'{lat:.8f}')
        self.lon.setText(f'{lon:.8f}')
        self.map.choose(self.coords, center=center)
        self.target.setText(name or '地图选点')
        self.target_coords.setText(f'{lat:.7f}, {lon:.7f}')
        self.tabs.setCurrentIndex(0)
        self.controls()

    def coordinate_edited(self):
        """输入改变时使旧草稿失效，直至用户确认坐标。"""
        self.coords = None
        self.map.marker = None
        self.map.refresh_viewport()
        self.target.setText('编辑坐标')
        self.target_coords.setText('点击「在地图上查看草稿」确认。')
        self.controls()

    def show_entry(self):
        try:
            self.draft(point(self.lat.text().strip(), self.lon.text().strip()))
        except ValueError:
            self.status.setText('请输入有效坐标：纬度 ±90°，经度 ±180°。')

    def records(self, key):
        try:
            return json.loads(self.settings.value(key, '[]'))
        except (ValueError, TypeError):
            return []

    def refresh_places(self):
        self.map.favorites = self.records('favorites')
        self.map.refresh_viewport()

    def places(self, key):
        dialog = PlaceBrowser(self, key)
        dialog.setMinimumSize(0, 0)
        dialog.resize(min(460, self.width()), min(450, self.height()))
        dialog.open()

    def save_place(self):
        if self.coords is not None:
            self.name_place(self.coords, self.target.text())

    def name_place(self, coords, current, parent=None):
        name = text_prompt(parent or self, '收藏名称', '地点名称', '保存', 'bookmark', value=current)
        if name:
            rows = [r for r in self.records('favorites') if tuple(r[1:]) != coords]
            rows.insert(0, [name, *coords])
            self.settings.setValue('favorites', json.dumps(rows))
            self.refresh_places()

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
