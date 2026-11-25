"""Everywhere desktop for Windows. Device and network operations run off the Qt GUI thread."""
import asyncio
import concurrent.futures
import json
import os
from pathlib import Path
import sys
import threading
import time
from urllib.parse import urlencode

from PySide6 import QtCore as C, QtGui as G, QtWidgets as W

ROOT=Path(__file__).resolve().parents[1]
if not getattr(sys,'frozen',False):
    sys.path.insert(0,str(ROOT/'swift/Host/ModernBackend'))

from appearance import Dropdown, style
from core import device_key,point
from software import Software
from bluetooth_host import Bluetooth
from peripheral import Peripheral
from remote import Remote
from mapview import MapView,OSM,request


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


def button(text,handler):
    b=W.QPushButton(text)
    b.clicked.connect(handler)
    return b


class Desk(W.QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle('Everywhere')
        self.resize(1120,720)
        self.settings=C.QSettings()
        self.jobs=Jobs()
        self.jobs.notice.connect(self.log)
        self.soft=Software()
        self.jobs.link_changed.connect(self.controls, C.Qt.QueuedConnection)
        self.bt=Bluetooth(self.bt_event, changed=self.jobs.link_changed.emit)
        self.reverse=Peripheral(self.bt.bundle)
        self.beacon=Peripheral(self.bt.bundle)
        self.remote=Remote(self.soft,self.jobs.notice.emit)
        self.busy=self.scanning=self.closing=self.closed=False
        self.epoch=0
        self.last_query=0
        self.mode='software'
        self.bt_target=''
        self.catalog={}
        layout=W.QStackedWidget()
        self.stack=layout
        self.setCentralWidget(layout)
        style(self)
        modes=W.QWidget()
        modes.setObjectName('chooser')
        col=W.QVBoxLayout(modes)
        col.setContentsMargins(64,48,64,48)
        col.addStretch()
        title=W.QLabel('选择定位模式')
        title.setStyleSheet('font-size:30px;font-weight:650')
        col.addWidget(title)
        cards=W.QHBoxLayout()
        for mode,label in [('classic','蓝牙模式\n连接 iAP2 配件或手机 App'),('software','软件模拟模式\n自动识别 USB 和 Wi-Fi 设备')]:
            card=button(label,lambda checked=False,k=mode:self.enter(k))
            card.setObjectName('modeCard')
            card.setMinimumHeight(120)
            cards.addWidget(card)
        col.addLayout(cards)
        col.addStretch()
        layout.addWidget(modes)

        work=W.QWidget()
        root=W.QVBoxLayout(work)
        root.setContentsMargins(0,0,0,0)
        body=W.QSplitter(C.Qt.Horizontal)
        root.addWidget(body)
        area=W.QWidget()
        maps=W.QVBoxLayout(area)
        row=W.QHBoxLayout()
        self.search=W.QLineEdit()
        self.search.setPlaceholderText('搜索地点或地址')
        self.search.returnPressed.connect(self.lookup)
        row.addWidget(self.search)
        row.addWidget(button('搜索',self.lookup))
        row.addWidget(button('地点簿',self.places))
        row.addWidget(button('图层',self.layers))
        maps.addLayout(row)
        self.map=MapView()
        self.map.picked.connect(lambda a,b:self.draft((a,b),False))
        maps.addWidget(self.map,1)
        zoom=W.QHBoxLayout()
        zoom.addWidget(button('＋',lambda:self.map.zoom(1)))
        zoom.addWidget(button('－',lambda:self.map.zoom(-1)))
        zoom.addStretch()
        zoom.addWidget(button('收藏选点',self.save_place))
        maps.addLayout(zoom)
        body.addWidget(area)

        panel=W.QWidget()
        panel.setObjectName('inspector')
        panel.setMinimumWidth(314)
        side=W.QVBoxLayout(panel)
        side.setContentsMargins(16,16,16,14)
        head=W.QHBoxLayout()
        self.title=W.QLabel()
        self.title.setObjectName('heading')
        head.addWidget(self.title)
        head.addStretch()
        self.back=button('切换模式',self.leave)
        head.addWidget(self.back)
        side.addLayout(head)
        self.tabs=W.QTabWidget()
        side.addWidget(self.tabs,1)
        def page(label):
            scroll=W.QScrollArea()
            scroll.setWidgetResizable(True)
            scroll.setFrameShape(W.QFrame.NoFrame)
            widget=W.QWidget()
            column=W.QVBoxLayout(widget)
            column.setAlignment(C.Qt.AlignTop)
            scroll.setWidget(widget)
            self.tabs.addTab(scroll,label)
            return column
        place=page('地点')
        place.addWidget(W.QLabel('坐标 · WGS 84'))
        self.lat=W.QLineEdit()
        self.lon=W.QLineEdit()
        for label,field in [('纬度',self.lat),('经度',self.lon)]:
            field.setAccessibleName(label)
            field.setPlaceholderText(label)
            place.addWidget(field)
        place.addWidget(button('在地图中查看',self.show_entry))
        device=page('设备')
        self.roles=Dropdown()
        for label,value in [('iAP2 配件定位','classic'),('电脑扫描手机','central'),('手机扫描电脑','reverse')]:
            self.roles.addItem(label,value)
        device.addWidget(self.roles)
        self.pair=button('连接新 iPhone',self.discover_phone)
        self.pair.setObjectName('deviceCard')
        device.addWidget(self.pair)
        self.device_label=W.QLabel()
        self.device_label.setObjectName('caption')
        device.addWidget(self.device_label)
        self.devices=Dropdown()
        self.devices.setPlaceholderText('请选择设备')
        self.devices.setSizeAdjustPolicy(W.QComboBox.AdjustToMinimumContentsLengthWithIcon)
        device.addWidget(self.devices)
        self.refresh=button('刷新设备',self.scan)
        device.addWidget(self.refresh)
        self.refresh_result=W.QLabel()
        self.refresh_result.setWordWrap(True)
        device.addWidget(self.refresh_result)
        self.transport=Dropdown()
        for label,k in [('自动 · 优先 USB','auto'),('仅 USB','USB'),('仅 Wi-Fi','Network')]:
            self.transport.addItem(label,k)
        device.addWidget(self.transport)
        self.prepare=button('信任设备并启用 Wi-Fi',self.prepare_wifi)
        device.addWidget(self.prepare)
        self.code=W.QLineEdit()
        self.code.setPlaceholderText('手机显示的六位接收码')
        self.code.setMaxLength(6)
        self.code.setEchoMode(W.QLineEdit.Password)
        device.addWidget(self.code)
        self.ble_connect=button('连接手机',self.connect_selected)
        device.addWidget(self.ble_connect)
        self.remote_button=button('手机遥控',self.remote_dialog)
        device.addWidget(self.remote_button)
        session=page('会话')
        self.logview=W.QPlainTextEdit()
        self.logview.setReadOnly(True)
        self.logview.document().setMaximumBlockCount(100)
        session.addWidget(self.logview,1)
        self.status=W.QLabel('请选择设备')
        self.status.setWordWrap(True)
        side.addWidget(self.status)
        self.jitter=W.QCheckBox('发送位置随机抖动（半径 5 米）')
        self.jitter.setChecked(self.settings.value('iap2/jitter',True,type=bool))
        self.jitter.toggled.connect(lambda on:self.settings.setValue('iap2/jitter',on))
        side.addWidget(self.jitter)
        self.apply=button('发送地图选点',lambda:self.send('set'))
        self.apply.setObjectName('primary')
        side.addWidget(self.apply)
        actions=W.QHBoxLayout()
        self.clear=button('恢复定位',lambda:self.send('clear'))
        self.stop=button('断开连接',self.stop_bt)
        actions.addWidget(self.clear)
        actions.addWidget(self.stop)
        side.addLayout(actions)
        body.addWidget(panel)
        body.setChildrenCollapsible(False)
        body.setSizes([740,380])
        layout.addWidget(work)
        self.devices.currentIndexChanged.connect(self.controls)
        self.devices.activated.connect(self.device_activated)
        self.roles.currentIndexChanged.connect(self.switch_role)
        for field in (self.lat,self.lon,self.code):
            field.textChanged.connect(self.controls)
        self.transport.currentIndexChanged.connect(self.controls)
        self.timer=C.QTimer(self)
        self.timer.setInterval(9000)
        self.timer.timeout.connect(self.auto_scan)

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

    def draft(self,coords,center=True):
        a,b=point(*coords)
        self.lat.setText(f'{a:.8f}')
        self.lon.setText(f'{b:.8f}')
        self.map.choose((a,b),center)

    def coords(self):
        return point(self.lat.text().strip(),self.lon.text().strip())

    def show_entry(self):
        try: self.draft(self.coords())
        except ValueError as e: self.log(str(e))

    def enter(self,mode):
        self.epoch+=1
        self.mode=mode
        self.devices.clear()
        self.catalog={}
        self.roles.blockSignals(True)
        ix=self.roles.findData(mode)
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
        self.roles.setVisible(not sw)
        self.remote_button.setVisible(sw)
        self.remote_button.setEnabled(not self.busy)
        self.transport.setVisible(sw)
        self.prepare.setVisible(sw)
        row=self.catalog.get(self.devices.currentData(),{})
        self.prepare.setEnabled(ready and row.get('usb',False))
        self.device_label.setText('已有iPhone连接' if classic else '目标设备')
        self.pair.setVisible(classic)
        self.pair.setEnabled(not self.busy and not self.scanning and not self.bt.classic_id)
        self.ble_connect.setVisible(self.mode=='central')
        self.ble_connect.setEnabled(ready and not self.bt.ble_id)
        self.jitter.setVisible(classic)
        self.code.setVisible(not sw and not classic)
        self.stop.setVisible(self.mode in ('classic','central'))
        linked = bool(self.bt.classic_id or self.bt.ble_id)
        self.stop.setEnabled(not self.busy and linked)
        self.devices.setEnabled(not self.busy and not linked)
        self.roles.setEnabled(not self.busy and not linked)
        self.refresh.setEnabled(not self.busy and not self.scanning and not linked)
        self.refresh.setText('刷新中…' if self.scanning else '刷新设备')
        try:
            self.coords()
            valid=True
        except ValueError:
            valid=False
        self.apply.setEnabled(ready and valid and self.send_ready())
        self.clear.setVisible(not classic)
        self.clear.setEnabled(ready and self.send_ready(recover=True))
        self.clear.setText('恢复真实定位' if sw else '清除手机 App 标记')
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
            return self.bt.ready and self.bt.classic_id==dev
        code=self.code.text()
        return (len(code)==6 and code.isascii() and code.isdigit() and
                (self.mode=='reverse' or self.bt.ble_id==dev))

    def device_activated(self,index):
        if self.mode=='classic' and index>=0:
            self.connect_selected()

    def connect_selected(self):
        dev=self.devices.currentData()
        if not dev or self.busy:
            return
        mode=self.mode
        self.bt_target=self.devices.currentText()
        async def run():
            if mode=='central':
                await self.bt.connect_ble(dev)
                return '手机接收服务已连接'
            await self.bt.connect_accessory(dev)
            try:
                await self.beacon.start(status=True)
            except Exception as exc:
                self.jobs.notice.emit('手机状态广播不可用 · '+str(exc))
            return None
        self.log('正在连接 '+self.bt_target)
        self.job(run(),lambda msg,error:self.log(msg) if msg else None)

    def discover_phone(self):
        def choose(rows,error):
            if error:
                return
            if not rows:
                self.log('未发现设备，请解锁 iPhone 并停留在「设置 → 蓝牙」')
                return
            choices=[r['name']+' · '+r['id'] for r in rows]
            text,ok=W.QInputDialog.getItem(self,'连接新 iPhone','附近蓝牙设备',choices,0,False)
            if ok:
                row=rows[choices.index(text)]
                dev=row['id']
                if dev not in self.catalog:
                    self.catalog[dev]=row
                    self.devices.addItem(text,dev)
                self.devices.setCurrentIndex(self.devices.findData(dev))
                self.connect_selected()
        self.log('正在搜索附近的经典蓝牙设备…')
        self.job(self.bt.scan('nearby'),choose)

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
            old=self.devices.currentData()
            rows,msg=result if result else ([],error)
            catalog={r['id']:r for r in rows}
            if not automatic:
                change='列表无变化 · ' if self.catalog==catalog else ''
                self.refresh_result.setText(time.strftime('%H:%M:%S')+' 已刷新 · '+change+f'{len(rows)} 台设备' if not error else '刷新失败 · '+error)
            self.catalog=catalog
            self.devices.blockSignals(True)
            self.devices.clear()
            for row in rows:
                links=' / '.join(label for k,label in [('usb','USB'),('wifi','Wi-Fi')] if row.get(k))
                self.devices.addItem(f"{row['name']}   {links}",row['id'])
            ix=self.devices.findData(old) if old else -1
            if ix>=0:self.devices.setCurrentIndex(ix)
            elif old or len(rows)!=1 or mode=="classic":self.devices.setCurrentIndex(-1)
            self.devices.blockSignals(False)
            if msg and msg!=getattr(self,'last_scan_msg',None):self.log(msg)
            self.last_scan_msg=msg
            self.controls()
        self.scan_future=self.jobs.submit(run(),end)

    def auto_scan(self):
        if self.stack.currentIndex() and self.mode in ('software','reverse','classic') and not self.closing:self.scan(automatic=True)

    def switch_role(self,index):
        if self.mode=='software' or self.busy:return
        new=self.roles.itemData(index)
        self.epoch+=1
        self.job(self.shutdown_links(),lambda _,err:None if err else self.enter(new))

    def prepare_wifi(self):
        serial=self.devices.currentData()
        if serial:
            self.job(self.soft.prepare(serial),lambda _,e:None if e else self.log('设备已确认 Wi-Fi 设置，可以拔线后刷新'))

    def confirm_send(self):
        dialog=W.QMessageBox(self)
        dialog.setWindowTitle('发送选点前请确认')
        dialog.setText('发送后，在目标设备的「设置 → 隐私与安全性 → 定位服务」关闭再打开定位服务。')
        dialog.setInformativeText('如需恢复，先点击恢复或停止会话，再关闭并打开定位服务。仍未生效时，请重启手机。')
        accept=dialog.addButton('我已知晓', W.QMessageBox.AcceptRole)
        cancel=dialog.addButton('取消', W.QMessageBox.RejectRole)
        dialog.setDefaultButton(cancel)
        dialog.exec()
        return dialog.clickedButton() is accept

    def send(self,action):
        recover=action=='clear'
        if self.busy or not self.send_ready(recover):
            return
        dev=self.devices.currentData()
        mode,epoch=self.mode,self.epoch
        code,jitter,link=self.code.text(),self.jitter.isChecked(),self.transport.currentData()
        proc,generation,client=self.bt.proc,self.bt.generation,self.bt.ble
        session=self.soft.get(dev) if mode=='software' else None
        revision=session.revision if session else None
        try:
            coords=None if recover else self.coords()
        except ValueError as error:
            self.log(str(error))
            return
        if not recover and not self.confirm_send():
            return
        if self.epoch!=epoch or self.devices.currentData()!=dev or not self.send_ready(recover):
            self.log('连接已变化，请重新选择设备')
            return
        async def run():
            if session:
                await session.execute(coords,link,revision=revision)
                return '开发定位调用已返回，请在手机核对最新系统位置'
            if mode=='classic':
                await self.bt.update_point(dev,coords,jitter,proc,generation)
                return '选点已提交，等待手机订阅和链路回执'
            if mode=='reverse':
                await self.reverse.marker(dev,code,coords)
            else:
                await self.bt.marker(dev,code,coords,client)
            return '手机 App 已确认更新标记'
        def sent(result,error):
            if not error:
                self.log(result)
                if coords:self.remember('recent','最近选点',coords)
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
            if not error:self.log('蓝牙会话已结束，请在手机核对最新位置')
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
            if error and W.QMessageBox.question(self,'恢复结果未知','无法确认设备恢复。仍退出 Everywhere？')!=W.QMessageBox.Yes:
                self.timer.start()
                return
            self.closed=True
            self.jobs.loop.call_soon_threadsafe(self.jobs.loop.stop)
            self.close()
        self.job(stop(),done)

    def lookup(self):
        query=self.search.text().strip()
        if not query or time.monotonic()-self.last_query<1:return
        self.last_query=time.monotonic()
        url='https://nominatim.openstreetmap.org/search?'+urlencode(dict(q=query,format='jsonv2',limit=7))
        reply=self.map.net.get(request(url))
        def done():
            try:
                if reply.error():raise ValueError(reply.errorString())
                rows=json.loads(bytes(reply.readAll()))
                if not rows:raise ValueError('未找到地点')
                names=[r['display_name'] for r in rows]
                choice,ok=W.QInputDialog.getItem(self,'搜索地点','搜索结果',names,0,False)
                if ok:
                    item=rows[names.index(choice)]
                    self.draft(point(item['lat'],item['lon']))
            except (ValueError,KeyError) as e:self.log(str(e))
            reply.deleteLater()
        reply.finished.connect(done)

    def records(self,key):
        try: return json.loads(self.settings.value(key,'[]'))
        except (ValueError,TypeError): return []

    def remember(self,key,name,coords):
        rows=[r for r in self.records(key) if tuple(r[1:])!=coords]
        rows.insert(0,[name,*coords])
        self.settings.setValue(key,json.dumps(rows[:100] if key=='recent' else rows))

    def save_place(self):
        try:coords=self.coords()
        except ValueError as e:
            self.log(str(e))
            return
        name,ok=W.QInputDialog.getText(self,'收藏选点','地点名称')
        if ok and name.strip():self.remember('favorites',name.strip(),coords)

    def places(self):
        rows=self.records('favorites')+self.records('recent')
        names=[f'{r[0]}  ·  {r[1]:.7f}, {r[2]:.7f}' for r in rows]
        if not names:
            self.log('地点簿为空，可先收藏一个地图选点')
            return
        name,ok=W.QInputDialog.getItem(self,'地点簿','收藏与最近地点',names,0,False)
        if ok:self.draft(rows[names.index(name)][1:])

    def layers(self):
        value,ok=W.QInputDialog.getItem(self,'底图','XYZ 图层',['OpenStreetMap · WGS 84','自定义 HTTPS 图层'],0,False)
        if not ok:return
        if value.startswith('OpenStreetMap'):
            self.map.layer(OSM,'© OpenStreetMap contributors',False)
            return
        url,ok=W.QInputDialog.getText(self,'自定义图层','包含 {z}、{x}、{y} 的 HTTPS 地址')
        if not ok:return
        try:
            rendered=url.format(z=1,x=1,y=1)
            if not all(k in url for k in ('{z}','{x}','{y}')) or not C.QUrl(rendered).host() or not url.startswith('https://'):
                raise ValueError()
        except (KeyError,IndexError,ValueError):
            self.log('图层地址无效')
            return
        datum,ok=W.QInputDialog.getItem(self,'坐标系','底图坐标系',['WGS 84','GCJ-02'],0,False)
        if not ok:return
        attribution,ok=W.QInputDialog.getText(self,'自定义图层','地图提供方署名')
        if ok and attribution.strip():self.map.layer(url,attribution.strip(),datum=='GCJ-02')

    def remote_dialog(self):
        actions=['开启 Wi-Fi / TCP 遥控','连接所选 USB 手机上的遥控端','停止遥控','撤销遥控配对']
        choice,ok=W.QInputDialog.getItem(self,'手机遥控','连接方式',actions,0,False)
        if not ok:return
        if choice==actions[0]:
            port,ok=W.QInputDialog.getInt(self,'网络遥控','TCP 监听端口',int(self.settings.value('port',49372)),1,65535)
            if not ok:return
            self.settings.setValue('port',port)
            task=self.remote.start_network(port)
        elif choice==actions[1]:
            if not self.devices.currentData():
                self.log('请选择已接线的手机')
                return
            task=self.remote.start_usb(self.devices.currentData())
        elif choice==actions[2]:task=self.remote.stop()
        else:task=self.remote.revoke()
        def done(key,e):
            if not e and key:W.QMessageBox.information(self,'手机遥控配对码','在手机 Everywhere 输入以下配对码\n\n'+key)
            elif not e:self.log('遥控已停止')
        self.job(task,done)


def main():
    smoke='--smoke-test' in sys.argv
    if smoke: os.environ['QT_QPA_PLATFORM']='offscreen'
    if sys.stderr is None: sys.stderr=open(os.devnull,'w',encoding='utf-8')
    if sys.stdout is None: sys.stdout=open(os.devnull,'w',encoding='utf-8')
    app=W.QApplication(sys.argv)
    app.setApplicationName('Everywhere')
    app.setOrganizationName('Everywhere')
    job=None
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
        except pywintypes.error:
            job=None
    w=Desk()
    if smoke:
        import portable_location
        import bleak
        import keyring.backends.Windows
        from remote import tls_context
        tls_context('0'*32,True)
        from importlib.metadata import version
        from inspect import signature
        assert version('pymobiledevice3') == portable_location.BACKEND_VERSION
        assert 'consumer' in signature(portable_location.session).parameters
        C.QTimer.singleShot(0,w.close)
    w.show()
    result=app.exec()
    if job is not None:
        # Retain the last job handle until OS process teardown.
        job.Detach()
    return result


if __name__=='__main__':
    sys.exit(main())
