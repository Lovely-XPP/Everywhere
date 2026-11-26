"""Shared search, favorites, and recent places sheet for the Qt console."""
import json
import time
from urllib.parse import urlencode

from PySide6 import QtCore as C, QtNetwork as N, QtWidgets as W
from appearance import icon, label
from console_ui import button, segment
from dialogs import ModalDialog, confirm
from core import point
from mapview import request


class PlaceBrowser(ModalDialog):
    keys=('search','favorites','recent')

    def __init__(self,desk,initial):
        super().__init__(desk,'地点簿','map')
        self.desk=desk
        self.reply=None
        self.setAttribute(C.Qt.WA_DeleteOnClose)
        self.resize(460,450)
        self.setMinimumSize(420,380)
        layout=self.body
        self.tabs=segment(layout,[('搜索','search','search'),('收藏','bookmark','favorites'),('最近','clock','recent')])
        self.entry=W.QWidget()
        row=W.QHBoxLayout(self.entry); row.setContentsMargins(0,0,0,0)
        self.query=W.QLineEdit(); self.query.setPlaceholderText('地点、地址或地标')
        self.submit=button('搜索',self.search)
        self.query.returnPressed.connect(self.search)
        self.query.textChanged.connect(self.refresh)
        row.addWidget(self.query,1); row.addWidget(self.submit)
        layout.addWidget(self.entry)
        self.empty=label('','muted',True)
        self.empty.setAlignment(C.Qt.AlignCenter)
        layout.addWidget(self.empty,1)
        self.items=W.QListWidget()
        self.items.setAccessibleName('地点列表')
        self.items.setTextElideMode(C.Qt.ElideRight)
        self.items.itemClicked.connect(self.choose)
        self.items.itemActivated.connect(self.choose)
        self.items.setContextMenuPolicy(C.Qt.CustomContextMenu)
        self.items.customContextMenuRequested.connect(self.manage)
        layout.addWidget(self.items,1)
        self.clear_button=button('清空最近使用',self.clear_recent)
        footer=W.QHBoxLayout()
        self.clear_button.setObjectName('dialogQuiet')
        footer.addWidget(self.clear_button)
        footer.addStretch()
        close=button('关闭',self.reject)
        close.setObjectName('dialogCancel')
        footer.addWidget(close)
        self.shell.addLayout(footer)
        for control in self.findChildren(W.QPushButton):
            control.setAutoDefault(False)
        self.tabs.setCurrentIndex(self.keys.index(initial))
        self.tabs.currentChanged.connect(self.refresh)
        self.finished.connect(self.cancel)
        self.refresh()
        if initial=='search': self.query.setFocus()

    @property
    def key(self):
        return self.keys[self.tabs.currentIndex()]

    def cancel(self,*_):
        reply,self.reply=self.reply,None
        if reply is not None: reply.abort()

    def refresh(self,*_):
        self.cancel()
        search=self.key=='search'
        self.entry.setVisible(search)
        self.submit.setEnabled(bool(self.query.text().strip()))
        self.rows([] if search else self.desk.records(self.key))
        self.empty.setText({'favorites':'在地图上选点，点“收藏”并为地点命名。',
                            'recent':'成功应用的地点会出现在这里。',
                            'search':'输入地名或地址，搜索地图上的地点。'}[self.key])

    def rows(self,records):
        self.items.clear()
        for name,lat,lon in records:
            summary=f'{name}\n{lat:.7f}, {lon:.7f}'
            item=W.QListWidgetItem(icon({'search':'location','favorites':'bookmark','recent':'clock'}[self.key]),summary)
            item.setData(C.Qt.UserRole,(name,lat,lon))
            item.setToolTip(summary)
            self.items.addItem(item)
        self.items.setVisible(bool(records))
        self.empty.setVisible(not records)
        self.clear_button.setVisible(self.key=='recent' and bool(records))

    def search(self):
        query=self.query.text().strip()
        if not query or self.reply is not None: return
        if time.monotonic()-self.desk.last_query<1:
            self.empty.setText('请稍候再搜索。')
            return
        self.desk.last_query=time.monotonic()
        self.rows([])
        self.empty.setText('正在搜索…')
        url='https://nominatim.openstreetmap.org/search?'+urlencode(dict(q=query,format='jsonv2',limit=7))
        self.reply=reply=self.desk.map.net.get(request(url))
        def finished():
            try:
                if reply is not self.reply: return
                self.reply=None
                if reply.error()!=N.QNetworkReply.NetworkError.NoError:
                    status=reply.attribute(N.QNetworkRequest.HttpStatusCodeAttribute)
                    if status==429:
                        message='搜索请求过于频繁，请稍后重试。'
                    elif status:
                        message=f'地点服务返回 HTTP {status}，请稍后重试。'
                    elif reply.error()==N.QNetworkReply.NetworkError.TimeoutError:
                        message='搜索超时，请检查网络后重试。'
                    else:
                        message='无法连接地点服务 · '+reply.errorString()
                    self.empty.setText(message)
                    return
                data=json.loads(bytes(reply.readAll()))
                if not isinstance(data,list): raise ValueError('unexpected response')
                rows=[]
                for item in data:
                    try:
                        name=item['display_name']
                        if isinstance(name,str) and name.strip():
                            rows.append((name,*point(item['lat'],item['lon'])))
                    except (ValueError,TypeError,KeyError):
                        continue
                if data and not rows: raise ValueError('invalid place records')
                self.rows(rows)
                if not rows: self.empty.setText('未找到地点，请更换关键词。')
            except (ValueError,TypeError,KeyError):
                self.empty.setText('无法读取搜索结果，请重试。')
            finally:
                reply.deleteLater()
        reply.finished.connect(finished)

    def choose(self,item):
        name,lat,lon=item.data(C.Qt.UserRole)
        self.desk.draft((lat,lon),name=name)
        self.accept()

    def manage(self,pos):
        item=self.items.itemAt(pos)
        if self.key!='favorites' or item is None: return
        name,lat,lon=item.data(C.Qt.UserRole)
        menu=W.QMenu(self)
        rename=menu.addAction('重命名')
        remove=menu.addAction('移除收藏')
        chosen=menu.exec(self.items.viewport().mapToGlobal(pos))
        if chosen is rename:
            self.desk.name_place((lat,lon),name,parent=self)
        elif chosen is remove:
            records=[r for r in self.desk.records('favorites') if tuple(r[1:])!=(lat,lon)]
            self.desk.settings.setValue('favorites',json.dumps(records))
            self.desk.refresh_places()
        self.refresh()

    def clear_recent(self):
        if confirm(self,'清空最近使用','清空本机最近使用的地点？','清空记录',symbol='clock',destructive=True):
            self.desk.settings.remove('recent')
            self.desk.refresh_places()
            self.refresh()
