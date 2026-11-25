"""Interactive, cached XYZ map. Fetch only the visible viewport."""
import collections
import math
import time
from pathlib import Path
from PySide6 import QtCore as C, QtGui as G, QtWidgets as W, QtNetwork as N
from geo import project,unproject,display,from_map

OSM='https://tile.openstreetmap.org/{z}/{x}/{y}.png'
USER_AGENT=b'EverywhereDesktop/1.0 (iPhone location controller)'


def request(url):
    r=N.QNetworkRequest(C.QUrl(url))
    r.setRawHeader(b'User-Agent',USER_AGENT)
    r.setTransferTimeout(12000)
    return r


class MapView(W.QWidget):
    picked=C.Signal(float,float)
    def __init__(self):
        super().__init__()
        self.template,self.attribution,self.gcj=OSM,'© OpenStreetMap contributors',False
        self.z=12
        self.center=(23.1291,113.2644)
        self.marker=None
        self.tiles=collections.OrderedDict()
        self.pending=set()
        self.failed={}
        self.press=None
        self.moved=False
        self.net=N.QNetworkAccessManager(self)
        directory=Path(C.QStandardPaths.writableLocation(C.QStandardPaths.CacheLocation))/'tiles'
        self.cache=N.QNetworkDiskCache(self)
        self.cache.setCacheDirectory(str(directory))
        self.cache.setMaximumCacheSize(96*1024**2)
        self.net.setCache(self.cache)
        self.setMinimumSize(320,280)

    def layer(self,template,attribution,gcj):
        self.template,self.attribution,self.gcj=template,attribution,gcj
        self.update()

    def fetch(self,url):
        if url in self.pending or self.failed.get(url,0)>time.monotonic():
            return
        self.pending.add(url)
        r=request(url)
        r.setAttribute(N.QNetworkRequest.CacheLoadControlAttribute,N.QNetworkRequest.PreferCache)
        reply=self.net.get(r)
        def finished():
            self.pending.discard(url)
            tile=G.QPixmap()
            if reply.error()==N.QNetworkReply.NoError and tile.loadFromData(reply.readAll()):
                self.tiles[url]=tile
                while len(self.tiles)>200: self.tiles.popitem(last=False)
            else:
                self.failed[url]=time.monotonic()+60
                if len(self.failed)>512: self.failed.pop(next(iter(self.failed)))
            reply.deleteLater()
            self.update()
        reply.finished.connect(finished)

    def origin(self):
        x,y=project(*display(*self.center,self.gcj),self.z)
        return x-self.width()/2,y-self.height()/2

    def paintEvent(self,event):
        p=G.QPainter(self)
        p.fillRect(self.rect(),G.QColor('#e9edf0'))
        left,top=self.origin()
        count=2**self.z
        for x in range(math.floor(left/256),math.floor((left+self.width())/256)+1):
            for y in range(max(0,math.floor(top/256)),min(count,math.floor((top+self.height())/256)+1)):
                box=C.QRect(round(256*x-left),round(256*y-top),256,256)
                url=self.template.format(z=self.z,x=x%count,y=y)
                tile=self.tiles.get(url)
                if tile:
                    p.drawPixmap(box,tile)
                else:
                    p.setPen(G.QColor('#dbe2e7'))
                    p.drawRect(box)
                    self.fetch(url)
        if self.marker:
            x,y=project(*display(*self.marker,self.gcj),self.z)
            world=count*256
            dx=(x-left-self.width()/2+world/2)%world-world/2
            p.setRenderHint(G.QPainter.Antialiasing)
            p.setPen(G.QPen(G.QColor('white'),3))
            p.setBrush(G.QColor('#c04d28'))
            p.drawEllipse(C.QPointF(dx+self.width()/2,y-top),8,8)
        label=self.attribution
        if self.failed and not self.tiles:
            label='底图加载失败 · 可手输经纬度    '+label
        p.setPen(G.QColor('#27343a'))
        w=p.fontMetrics().horizontalAdvance(label)+12
        p.fillRect(self.width()-w,self.height()-22,w,22,G.QColor('#fafafa'))
        p.drawText(self.width()-w+5,self.height()-6,label)

    def choose(self,coords,center=True):
        self.marker=coords
        if center: self.center=coords
        self.update()

    def mousePressEvent(self,event):
        if event.button()==C.Qt.LeftButton:
            self.press=event.pos()
            self.initial=self.origin()
            self.moved=False

    def mouseMoveEvent(self,event):
        if self.press is None: return
        delta=event.pos()-self.press
        if delta.manhattanLength()>4: self.moved=True
        if self.moved:
            x,y=self.initial
            self.center=from_map(*unproject(x+self.width()/2-delta.x(),y+self.height()/2-delta.y(),self.z),self.gcj)
            self.update()

    def mouseReleaseEvent(self,event):
        if self.press is not None and not self.moved:
            x,y=self.origin()
            coords=from_map(*unproject(x+event.pos().x(),y+event.pos().y(),self.z),self.gcj)
            self.picked.emit(*coords)
        self.press=None

    def zoom(self,step):
        self.z=max(1,min(19,self.z+step))
        self.update()

    def wheelEvent(self,event):
        if event.angleDelta().y(): self.zoom(1 if event.angleDelta().y()>0 else -1)
        event.accept()
