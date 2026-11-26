"""Everywhere Qt desktop for macOS, Windows and Linux. Device and network operations run off the Qt GUI thread."""
import asyncio
import concurrent.futures
import json
import os
from pathlib import Path
import sys
import threading
import time

from PySide6 import QtCore as C, QtGui as G, QtWidgets as W

ROOT=Path(__file__).resolve().parents[1]
if not getattr(sys,'frozen',False):
    sys.path.insert(0,str(ROOT/'swift/Host/ModernBackend'))

from app_version import VERSION
from appearance import icon, style
from console_ui import chooser, workspace
from dialogs import DATUM_OPTIONS, choose_program, confirm, custom_layer, text_prompt
from place_browser import PlaceBrowser
from core import device_key,point
from software import Software
from bluetooth_host import Bluetooth
if sys.platform == "darwin":
    from mac_bluetooth import MacBluetooth as Peripheral
else:
    from peripheral import Peripheral
from remote import Remote
from mapview import OSM


class Jobs(C.QObject):
    done=C.Signal(object,object,object)
    notice=C.Signal(str)
    link_changed=C.Signal()
    def __init__(self):
        super().__init__()
        self.loop=asyncio.new_event_loop()
        self.thread=threading.Thread(target=self.loop.run_forever,daemon=True)
        self.thread.start()
        self.done.connect(self.deliver,C.Qt.QueuedConnection)

    @C.Slot(object,object,object)
    def deliver(self,callback,result,error):
        callback(result,error)

    def submit(self,coro,callback):
        def finished(f):
            try: result,error=f.result(),None
            except (Exception,concurrent.futures.CancelledError) as exc: result,error=None,str(exc) or type(exc).__name__
            self.done.emit(callback,result,error)
        future=asyncio.run_coroutine_threadsafe(coro,self.loop)
        future.add_done_callback(finished)
        return future


class Desk(W.QMainWindow):
    def __init__(self, *, smoke_test=False):
        super().__init__()
        self.smoke_test=smoke_test
        self.setWindowTitle('Everywhere')
        self.resize(1120,720)
        self.settings=C.QSettings()
        self.jobs=Jobs()
        self.jobs.notice.connect(self.log, C.Qt.QueuedConnection)
        self.soft=Software()
        self.jobs.link_changed.connect(self.controls, C.Qt.QueuedConnection)
        self.bt=Bluetooth(self.bt_event, changed=self.jobs.link_changed.emit)
        self.reverse_started=False
        self.reverse=Peripheral(self.bt.bundle)
        self.beacon=Peripheral(self.bt.bundle)
        self.remote=Remote(self.soft,self.jobs.notice.emit)
        self.busy=self.scanning=self.closing=self.closed=False
        self.epoch=0
        self.last_query=0
        self.mode='software'
        self.showing_pairing=False
        self.named_place=None
        self.bt_target=''
        self.catalog={}
        layout=W.QStackedWidget()
        self.stack=layout
        self.setCentralWidget(layout)
        style(self)
        self.setMinimumSize(800,560)
        layout.addWidget(chooser(self))
        layout.addWidget(workspace(self))
        self.select_datum(self.settings.value('map/gcj',False,type=bool))
        for field in (self.start_datum,self.place_datum):
            field.currentIndexChanged.connect(lambda _,picker=field:self.select_datum(picker.currentData()))
        self.map.show_favorites=self.settings.value('map/favoritesVisible',True,type=bool)
        self.refresh_places()
        W.QApplication.instance().paletteChanged.connect(self.update_appearance)
        self.devices.currentIndexChanged.connect(self.controls)
        self.devices.activated.connect(self.device_activated)
        self.roles.currentChanged.connect(self.switch_role)
        for field in (self.lat,self.lon,self.code):
            field.textChanged.connect(self.controls)
        self.transport.currentIndexChanged.connect(self.controls)
        self.remote_port.textChanged.connect(self.controls)
        self.timer=C.QTimer(self)
        self.timer.setInterval(9000)
        self.timer.timeout.connect(self.auto_scan)

    def update_appearance(self,*_):
        style(self)
        self.map.update()

    def select_datum(self,gcj):
        # This preference labels the basemap. The Qt renderer uses aligned WGS 84 coordinates.
        self.settings.setValue('map/gcj',gcj)
        for field in (self.start_datum,self.place_datum):
            with C.QSignalBlocker(field):
                field.setCurrentIndex(field.findData(gcj))

    def refresh_places(self):
        favorites=self.records('favorites')
        self.map.favorites=favorites
        self.map.update()
        recent=self.records('recent')
        self.shortcuts['favorites'].setText(f'{len(favorites)} 个地点')
        self.shortcuts['recent'].setText(recent[0][0] if recent else '暂无记录')
        self.update_destination()

    def update_destination(self):
        try:
            a,b=self.coords()
        except ValueError:
            self.place_title.setText('选择目的地')
            self.place_coord.setText('点按地图，或搜索地点名称')
            self.save.hide()
            self.view_point.setEnabled(False)
            return
        favorite=next((r for r in self.records('favorites') if tuple(r[1:])==(a,b)),None)
        title=favorite[0] if favorite else self.named_place[0] if self.named_place and self.draft_matches(self.named_place[1]) else '地图选点'
        self.place_title.setText(title)
        self.place_coord.setText(f'{a:.7f}, {b:.7f}')
        self.save.show()
        self.save.setText('已收藏' if favorite else '收藏')
        self.view_point.setEnabled(True)

    def bt_event(self,msg):
        self.jobs.notice.emit(msg)
        if self.beacon.proc and self.beacon.proc.returncode is None:
            async def update():
                try: await self.beacon.update(self.bt_target,self.bt.authenticated,msg)
                except (OSError,ConnectionError): pass
            asyncio.create_task(update())

    def log(self,msg):
        self.status.setText(msg)
        self.logview.appendPlainText(time.strftime('%H:%M:%S')+'  '+msg)

    def draft_matches(self,coords):
        try:
            return all(abs(x-y)<0.000000006 for x,y in zip(self.coords(),coords))
        except ValueError:
            return False

    def draft(self,coords,center=True,name=None):
        a,b=point(*coords)
        self.named_place=(name,(a,b)) if name else None
        self.lat.setText(f'{a:.8f}')
        self.lon.setText(f'{b:.8f}')
        self.map.choose((a,b),center,span=.025 if name else .05)
        self.update_destination()

    def coords(self):
        return point(self.lat.text().strip(),self.lon.text().strip())

    def show_entry(self):
        try: self.draft(self.coords())
        except ValueError as e: self.log(str(e))

    def enter(self,mode):
        self.epoch+=1
        self.reverse_started=False
        self.preferred_device=None
        self.showing_pairing=False
        self.software_devices.clear()
        self.mode=mode
        self.devices.clear()
        self.catalog={}
        self.roles.blockSignals(True)
        ix=next((i for i in range(self.roles.count()) if self.roles.tabData(i)==mode),-1)
        if ix>=0:self.roles.setCurrentIndex(ix)
        self.roles.blockSignals(False)
        self.tabs.setCurrentIndex(1)
        self.refresh_result.clear()
        self.status.setText("请选择目标设备")
        self.stack.setCurrentIndex(1)
        self.controls()
        self.scan()
        self.timer.start()

    def controls(self,*_):
        sw=self.mode=='software'
        classic=self.mode=='classic'
        ready=self.devices.currentIndex()>=0 and not self.busy
        self.title.setText('软件模拟模式' if sw else '蓝牙模式')
        self.bt_group.setVisible(not sw)
        self.advanced.setVisible(sw)
        self.transport_group.setVisible(sw and self.advanced.isChecked())
        self.remote_group.setVisible(sw)
        self.target_row.setVisible(not classic)
        self.session_summary.setVisible(not classic)
        pairing=classic and self.showing_pairing
        self.device_title.setText(("连接新 iPhone" if pairing else "iAP2 配件会话") if classic else "目标设备")
        self.device_controls.setVisible(not pairing)
        self.pairing_box.setVisible(pairing)
        self.retry_pair.setEnabled(not self.busy)
        self.role_hint.setText({"classic":"选择已配对的 iPhone 可检测 iAP2 握手。手机 Everywhere 的「手机扫描 Mac」可查看配件会话状态。",
                               "central":"在手机 Everywhere 开启蓝牙接收，连接手机并输入六位接收码，即可更新手机 App 地图标记。",
                               "reverse":"先开启电脑蓝牙广播，再用手机 Everywhere 扫描并连接本机。输入手机显示的六位接收码。"}.get(self.mode,""))
        self.transport.setVisible(sw)
        self.wifi_address.setVisible(sw and self.transport.currentData()=='Network')
        self.wifi_address.setEnabled(not self.busy and not self.scanning)
        row=self.catalog.get(self.devices.currentData(),{})
        network=self.remote.server is not None
        usb=self.remote.usb is not None
        self.remote_group.setEnabled(not self.busy)
        self.remote_network.setText('网络遥控已开启' if network else '开启网络遥控')
        self.remote_network.setEnabled(not network and self.remote_port.hasAcceptableInput())
        self.remote_port.setEnabled(not network)
        self.bonjour.setEnabled(not network)
        self.remote_usb.setEnabled(not usb and bool(row.get('usb')))
        self.remote_usb.setText('USB 遥控已开启' if usb else '连接 USB 手机')
        self.remote_stop.setVisible(network or usb)
        self.reveal.setVisible(network or usb)
        reveal=(network or usb) and self.reveal.isChecked()
        self.reveal.setText('隐藏配对码' if reveal else '显示配对码')
        self.remote_code.setVisible(reveal)
        self.remote_code.setText(self.remote.key if reveal and self.remote.key else '')
        self.prepare.setVisible(sw and bool(row.get('usb')))
        self.prepare.setEnabled(ready and row.get('usb',False))
        self.devices.setAccessibleName('已有iPhone连接' if classic else '目标设备')
        self.devices.setPlaceholderText(('选择 iPhone' if self.catalog else '暂无设备') if classic else '请选择设备')
        name=row.get('name') or '尚未选择'
        self.target_name.setText(name)
        self.target_name.setToolTip(self.devices.currentText())
        self.session_target.setText(name if row else '尚未选定设备。')
        self.update_destination()
        self.devices.setVisible(not sw)
        self.software_devices.setVisible(sw and bool(self.catalog))
        self.no_devices.setVisible(sw and not self.catalog)
        self.software_devices.setEnabled(not self.busy)
        with C.QSignalBlocker(self.software_devices):
            self.software_devices.setCurrentRow(self.devices.currentIndex() if sw else -1)
        self.auth.setVisible(classic)
        self.auth_box.setVisible(classic and self.auth.isChecked())
        provider=self.settings.value('iap2/authProvider','') or os.environ.get('EVERYWHERE_AUTH_PROVIDER','')
        self.provider.setText(provider or '使用内置 MFi 认证程序')
        self.reset_provider.setVisible(bool(self.settings.value('iap2/authProvider','')))
        self.auth_box.setEnabled(not self.busy and not self.bt.classic_id)
        self.pair.setVisible(classic)
        self.pair.setEnabled(not self.busy and not self.scanning and not self.bt.classic_id)
        reverse = self.mode == 'reverse'
        self.ble_connect.setVisible(self.mode == 'central' or reverse)
        self.ble_connect.setText('开启电脑蓝牙广播' if reverse else '连接手机')
        self.ble_connect.setEnabled(not self.busy and not self.reverse_started if reverse else ready and not self.bt.ble_id)
        self.jitter.setVisible(classic)
        self.code.setVisible(not sw and not classic)
        self.device_stop.setVisible(not sw)
        self.device_stop.setText('停止广播' if reverse else '断开连接')
        linked = bool(self.bt.classic_id or self.bt.ble_id)
        self.device_stop.setEnabled(not self.busy and (linked or self.reverse_started))
        self.devices.setEnabled(bool(self.catalog) and not self.busy and not linked)
        self.roles.setEnabled(not self.busy and not linked)
        self.refresh.setEnabled(not self.busy and not self.scanning and not linked and (not reverse or self.reverse_started))
        self.refresh.setText('刷新中' if self.scanning else '刷新')
        self.refresh_result.setVisible(bool(self.refresh_result.text()))
        try:
            self.coords()
            valid=True
        except ValueError:
            valid=False
        can_send=self.send_ready()
        if self.status.text() in ('请选择目标设备','等待发送地图选点','请在地图上选择目的地','已选择设备','当前连接方式不可用'):
            if not row: prompt='请选择目标设备'
            elif sw and not can_send: prompt='当前连接方式不可用'
            elif not can_send: prompt='已选择设备'
            else: prompt='等待发送地图选点' if valid else '请在地图上选择目的地'
            self.status.setText(prompt)
        self.apply.setEnabled(ready and valid and can_send)
        self.clear.setEnabled(ready and self.send_ready(recover=True))
        self.clear.setText('恢复真实定位' if sw or classic else '清除手机 App 标记')
        self.back.setEnabled(not self.busy)

    def send_ready(self, recover=False):
        dev=self.devices.currentData()
        row=self.catalog.get(dev)
        if not row:
            return False
        if self.mode=='software':
            link=self.transport.currentData()
            session=self.soft.devices.get(device_key(dev))
            if recover and session and session.active:
                return True
            available=(row.get('usb') and link!='Network') or (row.get('wifi') and link!='USB')
            return bool(available and (recover or not session or not session.unknown))
        if self.mode=='classic':
            if recover:
                return bool(self.bt.has_target and self.bt.classic_id==dev and self.bt.proc and self.bt.proc.returncode is None)
            return self.bt.ready and self.bt.classic_id==dev
        code=self.code.text()
        return (len(code)==6 and code.isascii() and code.isdigit() and
                (self.reverse_started and self.reverse.proc is not None and self.reverse.proc.returncode is None if self.mode=='reverse' else self.bt.ble_id==dev))

    def device_activated(self,index):
        if self.mode=='classic' and index>=0:
            self.connect_selected()

    def connect_selected(self):
        if self.mode == 'reverse':
            def started(_, error):
                self.reverse_started = not error
                if self.reverse_started:
                    self.log('广播已开启，请用手机 Everywhere 扫描并连接这台电脑')
                    self.scan()
            self.job(self.reverse.start(), started)
            return
        dev=self.devices.currentData()
        if not dev or self.busy:
            return
        mode=self.mode
        provider=self.settings.value('iap2/authProvider','')
        self.bt_target=self.devices.currentText()
        async def run():
            if mode=='central':
                await self.bt.connect_ble(dev)
                return '手机接收服务已连接'
            await self.bt.connect_accessory(dev,provider)
            try:
                await self.beacon.start(status=True)
            except Exception as exc:
                self.jobs.notice.emit('手机状态广播不可用 · '+str(exc))
            return None
        self.log('正在连接 '+self.bt_target)
        self.job(run(),lambda msg,error:self.log(msg) if msg else None)

    def set_provider(self,path):
        self.settings.setValue('iap2/authProvider',path)
        self.controls()

    def choose_provider(self):
        path=choose_program(self)
        if path:
            if not os.access(path,os.X_OK):
                self.log('所选认证程序不可执行')
                return
            self.set_provider(path)

    def discover_phone(self):
        if self.busy or self.mode!='classic' or self.bt.classic_id: return
        self.showing_pairing=True
        self.nearby.clear()
        self.nearby.hide()
        self.pairing_status.setText('正在搜索附近的经典蓝牙设备…')
        def choose(rows,error):
            if not self.showing_pairing: return
            for row in rows or []:
                item=W.QListWidgetItem(icon('phone'),row['name']+' · '+row['id'])
                item.setData(C.Qt.UserRole,row)
                self.nearby.addItem(item)
            self.nearby.setVisible(bool(rows))
            self.pairing_status.setText(error or ('选择要配对的 iPhone。' if rows else '未发现设备，请让 iPhone 停留在「设置 → 蓝牙」，然后重新搜索。'))
        self.job(self.bt.scan('nearby'),choose)

    def close_pairing(self):
        self.showing_pairing=False
        self.controls()

    def pair_nearby(self,item):
        if not self.showing_pairing or self.busy: return
        row=item.data(C.Qt.UserRole)
        dev=row['id']
        self.catalog[dev]=row
        if self.devices.findData(dev)<0: self.devices.addDevice(row['name'],dev,row['name']+' · '+dev)
        self.devices.setCurrentIndex(self.devices.findData(dev))
        self.close_pairing()
        self.connect_selected()

    def job(self,coro,done=None):
        if self.busy:
            coro.close()
            return
        self.busy=True
        self.controls()
        def end(result,error):
            self.busy=False
            if error: self.log(error)
            if done: done(result,error)
            self.controls()
        self.jobs.submit(coro,end)

    def scan(self, checked=False, *, automatic=False):
        if self.mode == 'reverse' and not self.reverse_started: return
        if self.scanning or self.busy or self.bt.classic_id or self.bt.ble_id or self.closing: return
        self.scanning=True
        self.controls()
        mode,epoch=self.mode,self.epoch
        async def run():
            if mode=='software': return await self.soft.scan()
            if mode=='reverse':
                peers=await self.reverse.peers()
                return [dict(id=k,name='手机 · '+bytes.fromhex(k).decode(errors='replace')[-26:]) for k in peers],'在手机选择「手机扫描 Mac」后刷新'
            return await self.bt.scan(mode),''
        def end(result,error):
            self.scanning=False
            if self.epoch!=epoch:
                self.controls()
                if self.stack.currentIndex()==1:self.scan()
                return
            old=getattr(self, 'preferred_device', None) or self.devices.currentData()
            self.preferred_device=None
            rows,msg=result if result else ([],error)
            catalog={r['id']:r for r in rows}
            if not automatic:
                change='列表无变化 · ' if self.catalog==catalog else ''
                self.refresh_result.setText(time.strftime('%H:%M:%S')+' 已刷新 · '+change+f'{len(rows)} 台设备' if not error else '刷新失败 · '+error)
            if mode == 'reverse' and error and (not self.reverse.proc or self.reverse.proc.returncode is not None):
                self.reverse_started=False
            changed=catalog!=self.catalog or list(catalog)!=list(self.catalog)
            if mode=='software' and changed:
                with C.QSignalBlocker(self.software_devices):
                    self.software_devices.clear()
                    for row in rows:
                        links=' / '.join(title for key,title in [('usb','USB'),('wifi','Wi-Fi')] if row.get(key))
                        item=W.QListWidgetItem(icon('phone'),row['name']+'\n'+links+' · '+row['id'][-8:])
                        item.setData(C.Qt.UserRole,row['id'])
                        item.setToolTip(row['id'])
                        self.software_devices.addItem(item)
                    self.software_devices.setFixedHeight(min(3,max(1,len(rows)))*52+2)
            self.catalog=catalog
            with C.QSignalBlocker(self.devices):
                if changed:
                    if self.devices.view().isVisible(): self.devices.hidePopup()
                    self.devices.clear()
                    for row in rows:
                        links=' / '.join(title for key,title in [('usb','USB'),('wifi','Wi-Fi')] if row.get(key))
                        identity=row['id']
                        detail=identity[-8:] if mode=='software' else identity if mode=='classic' else ''
                        summary=' · '.join(v for v in (row['name'],links,detail) if v)
                        self.devices.addDevice(row['name'],identity,summary)
                ix=self.devices.findData(old) if old else -1
                if ix<0 and not old and len(rows)==1 and mode!='classic': ix=0
                if ix!=self.devices.currentIndex(): self.devices.setCurrentIndex(ix)
            if msg and msg!=getattr(self,'last_scan_msg',None):self.log(msg)
            self.last_scan_msg=msg
            self.controls()
        self.scan_future=self.jobs.submit(run(),end)

    def auto_scan(self):
        if self.stack.currentIndex() and not self.showing_pairing and self.mode in ('software','reverse','classic') and not self.closing:self.scan(automatic=True)

    def switch_role(self,index):
        if self.mode=='software' or self.busy:return
        new=self.roles.tabData(index)
        self.epoch+=1
        self.job(self.shutdown_links(),lambda _,err:None if err else self.enter(new))

    def select_wifi_address(self):
        address=text_prompt(self,'验证 Wi-Fi 设备','已信任 iPhone 的 IPv4 或 IPv6 地址','验证连接','wifi')
        if not address:
            return
        def checked(serial,error):
            if not error:
                self.preferred_device=serial
                self.scan()
        self.job(self.soft.use_address(address.strip()),checked)

    def prepare_wifi(self):
        serial=self.devices.currentData()
        if serial:
            self.job(self.soft.prepare(serial),lambda _,e:None if e else self.log('设备已确认 Wi-Fi 设置，可以拔线后刷新'))

    def confirm_send(self):
        return confirm(self,'发送选点前请确认',
                       '发送后，在目标设备的「设置 → 隐私与安全性 → 定位服务」关闭再打开定位服务。','我已知晓',
                       detail='如需恢复，先点击恢复或停止会话，再关闭并打开定位服务。仍未生效时，请重启手机。')

    def confirm_restore(self):
        action=self.clear.text()
        instructions={
            'classic':'将结束 iAP2 配件会话。请在 iPhone 地图点“我的位置”核对新样本；若仍停留在旧点，请关闭再打开定位服务。',
            'software':'将通过所选设备的开发定位服务清除模拟位置。请保持连接，随后在手机地图或诊断页核对新样本。',
        }
        return confirm(self,action+'？','目标设备：'+self.devices.currentText(),action,
                       detail=instructions.get(self.mode,'将清除 Everywhere 手机上的蓝牙位置标记，保留接收连接。'))

    def send(self,action):
        recover=action=='clear'
        if self.busy or not self.send_ready(recover):
            return
        dev=self.devices.currentData()
        mode,epoch=self.mode,self.epoch
        code,jitter,link=self.code.text(),self.jitter.isChecked(),self.transport.currentData()
        proc,generation,client=self.bt.proc,self.bt.generation,self.bt.ble
        broadcast=self.reverse.proc
        session=self.soft.devices.get(device_key(dev)) if mode=='software' else None
        if mode=='software' and session is None: return
        revision=session.revision if session else None
        try:
            coords=None if recover else self.coords()
        except ValueError as error:
            self.log(str(error))
            return
        if not (self.confirm_restore() if recover else self.confirm_send()):
            return
        if self.epoch!=epoch or self.devices.currentData()!=dev or not self.send_ready(recover):
            self.log('连接已变化，请重新选择设备')
            return
        async def run():
            if session:
                await session.execute(coords,link,revision=revision)
                return '已收到清除模拟定位的回执，请在手机地图核对新样本。' if recover else '开发定位调用已返回，请在手机核对最新系统位置'
            if mode=='classic':
                if recover:
                    await self.bt.restore_accessory(dev,proc,generation)
                    await self.beacon.stop()
                    return '配件位置输出已结束，请在 iPhone 地图核对新的定位样本。'
                await self.bt.update_point(dev,coords,jitter,proc,generation)
                return '选点已提交，等待手机订阅和链路回执'
            if mode=='reverse':
                await self.reverse.marker(dev,code,coords,broadcast)
            else:
                await self.bt.marker(dev,code,coords,client)
            return '手机 App 已确认清除蓝牙位置标记' if recover else '手机 App 已确认更新标记'
        sent_name=self.place_title.text()
        def sent(result,error):
            if not error:
                self.log(result)
                if coords:self.remember('recent',sent_name,coords)
        self.job(run(),sent)

    async def shutdown_links(self):
        # 完成正在创建的 GATT 服务后再释放，避免退出页面时留下广播。
        scan=getattr(self,'scan_future',None)
        if scan is not None and not scan.done():
            await asyncio.gather(asyncio.wrap_future(scan),return_exceptions=True)
        await self.bt.stop()
        await self.reverse.stop()
        await self.beacon.stop()

    def stop_bt(self):
        def done(_,error):
            if not error:
                if self.mode == 'reverse':
                    self.reverse_started=False
                    self.catalog.clear()
                    self.devices.clear()
                self.log('蓝牙会话已结束，请在手机核对最新位置')
        self.job(self.shutdown_links(),done)

    def leave(self):
        self.timer.stop()
        self.epoch+=1
        async def stop():
            await self.remote.stop()
            await self.shutdown_links()
            for session in list(self.soft.devices.values()):
                if session.active or session.unknown: await session.execute(None)
        def done(_,error):
            if error:
                self.timer.start()
                return
            self.stack.setCurrentIndex(0)
        self.job(stop(),done)

    def closeEvent(self,event):
        if self.closed:
            event.accept()
            return
        event.ignore()
        if self.busy or self.closing:
            self.log('正在处理请求，请稍候')
            return
        self.closing=True
        self.timer.stop()
        self.epoch+=1
        async def stop():
            await self.remote.stop()
            await self.shutdown_links()
            for s in list(self.soft.devices.values()):
                if s.active or s.unknown: await s.execute(None)
        def done(_,error):
            self.closing=False
            if error and self.smoke_test:
                print(f'Qt shutdown failed: {error}',file=sys.stderr,flush=True)
                self.jobs.loop.call_soon_threadsafe(self.jobs.loop.stop)
                W.QApplication.exit(1)
                return
            if error and not confirm(self,'恢复结果未知','无法确认设备恢复。仍退出 Everywhere？','退出 Everywhere',
                                     cancel='留在应用',destructive=True):
                self.timer.start()
                return
            self.closed=True
            self.jobs.loop.call_soon_threadsafe(self.jobs.loop.stop)
            self.close()
        self.job(stop(),done)

    def records(self,key):
        try: return json.loads(self.settings.value(key,'[]'))
        except (ValueError,TypeError): return []

    def remember(self,key,name,coords):
        rows=[r for r in self.records(key) if tuple(r[1:])!=coords]
        rows.insert(0,[name,*coords])
        self.settings.setValue(key,json.dumps(rows[:100] if key=='recent' else rows))
        self.refresh_places()

    def save_place(self):
        try:coords=self.coords()
        except ValueError as e:
            self.log(str(e))
            return
        self.name_place(coords,self.place_title.text())

    def name_place(self,coords,current,parent=None):
        name=text_prompt(parent or self,'收藏名称','地点名称','保存','bookmark',value=current)
        if name:self.remember('favorites',name,coords)

    def places(self,key):
        dialog=PlaceBrowser(self,key)
        dialog.open()

    def layers(self,anchor):
        menu=W.QMenu(self)
        for title,gcj in DATUM_OPTIONS:
            option=menu.addAction(title)
            option.setCheckable(True)
            option.setChecked(self.place_datum.currentData()==gcj)
            option.triggered.connect(lambda checked=False,value=gcj:self.select_datum(value))
        menu.addSeparator()
        pins=menu.addAction('在地图上显示收藏')
        pins.setCheckable(True); pins.setChecked(self.map.show_favorites)
        menu.addSeparator()
        menu.addAction('刷新当前地图',self.map.refresh_tiles)
        osm=menu.addAction('OpenStreetMap')
        custom=menu.addAction('自定义 HTTPS 图层…')
        selected=menu.exec(anchor.mapToGlobal(C.QPoint(0,anchor.height())))
        if selected is pins:
            self.map.show_favorites=pins.isChecked()
            self.settings.setValue('map/favoritesVisible',pins.isChecked())
            self.map.update()
        if selected is osm:
            self.map.layer(OSM,'© OpenStreetMap contributors')
        if selected is not custom:return
        layer=custom_layer(self,self.place_datum.currentData())
        if layer:
            url,attribution,gcj=layer
            self.select_datum(gcj)
            self.map.layer(url,attribution)

    def remote_action(self,action):
        if self.busy: return
        self.reveal.setChecked(False)
        if action=='network':
            if not self.remote_port.hasAcceptableInput(): return
            port=int(self.remote_port.text())
            self.settings.setValue('port',port)
            task=self.remote.start_network(port,self.bonjour.isChecked())
        elif action=='usb':
            target=self.devices.currentData()
            if not self.catalog.get(target,{}).get('usb'): return
            task=self.remote.start_usb(target)
        elif action=='stop':
            task=self.remote.stop()
        else:
            task=self.remote.revoke()
        def done(_,error):
            if not error:
                self.log({'network':'网络遥控已开启','usb':'USB 遥控已开启',
                          'stop':'遥控已停止','revoke':'已撤销遥控配对'}[action])
        self.job(task,done)


def main():
    if sys.argv[1:]==['--version']:
        if sys.stdout is not None: print(VERSION)
        return 0
    smoke='--smoke-test' in sys.argv
    if smoke: os.environ['QT_QPA_PLATFORM']='offscreen'
    if sys.stderr is None: sys.stderr=open(os.devnull,'w',encoding='utf-8')
    if sys.stdout is None: sys.stdout=open(os.devnull,'w',encoding='utf-8')
    app=W.QApplication(sys.argv)
    app.setApplicationName('Everywhere')
    app.setApplicationVersion(VERSION)
    app.setOrganizationName('Everywhere')
    if sys.platform=='win32':
        # 进程被任务管理器终止时，让操作系统一并回收随宿主创建的蓝牙子进程。
        import win32api,win32job
        import pywintypes
        try:
            job=win32job.CreateJobObject(None,None)
            info=win32job.QueryInformationJobObject(job,win32job.JobObjectExtendedLimitInformation)
            info['BasicLimitInformation']['LimitFlags'] |= win32job.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            win32job.SetInformationJobObject(job,win32job.JobObjectExtendedLimitInformation,info)
            win32job.AssignProcessToJobObject(job,win32api.GetCurrentProcess())
            # 仅在进程退出时关闭句柄，启动异常仍有机会写入诊断日志。
            job.Detach()
        except pywintypes.error:
            pass
    w=Desk(smoke_test=smoke)
    if smoke:
        print('Checking device, Bluetooth, keyring and TLS dependencies',flush=True)
        import portable_location
        import importlib
        if sys.platform == 'win32':
            importlib.import_module('bleak.backends.winrt.client')
            importlib.import_module('bleak.backends.winrt.scanner')
        elif sys.platform == 'linux':
            importlib.import_module('bleak.backends.bluezdbus.client')
            importlib.import_module('linux_gatt')
        keyrings = {'darwin':'macOS', 'win32':'Windows', 'linux':'SecretService'}
        importlib.import_module('keyring.backends.'+keyrings[sys.platform])
        from remote import tls_context
        tls_context('0'*32,True)
        from importlib.metadata import version
        from inspect import signature
        assert version('pymobiledevice3') == portable_location.BACKEND_VERSION
        assert 'consumer' in signature(portable_location.session).parameters
        print('Showing and closing the Qt window',flush=True)
        C.QTimer.singleShot(0,w.close)
    w.show()
    return app.exec()


def dispatch():
    """按命令行启动桌面或辅助进程，并返回退出状态。"""
    if sys.argv[1:2] == ['--qt-worker']:
        from worker import main as worker_main
        del sys.argv[1]
        worker_main()
    elif sys.argv[1:2] == ['--linux-rfcomm']:
        from linux_rfcomm import main as bridge_main
        return bridge_main(sys.argv[2:])
    elif sys.argv[1:2] == ['--linux-gatt']:
        from linux_gatt import main as gatt_main
        asyncio.run(gatt_main(sys.argv[2:]))
    else:
        return main()


if __name__=='__main__':
    sys.exit(dispatch())
