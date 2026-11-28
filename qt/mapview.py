"""Interactive, cached XYZ map. Fetch only the visible viewport."""
import collections
import math
import os
import time
from pathlib import Path
from PySide6 import QtCore as C, QtGui as G, QtWidgets as W, QtNetwork as N
from geo import project,unproject
from appearance import draw_symbol
from app_version import VERSION

OSM='https://tile.openstreetmap.org/{z}/{x}/{y}.png'
USER_AGENT=f'EverywhereDesktop/{VERSION} (+https://github.com/Lovely-XPP/Everywhere)'


def request(url):
    r=N.QNetworkRequest(C.QUrl(url))
    r.setHeader(N.QNetworkRequest.KnownHeaders.UserAgentHeader,USER_AGENT)
    r.setTransferTimeout(12000)
    return r


class MapView(W.QWidget):
    picked=C.Signal(float,float)
    favorite_picked=C.Signal(str,float,float)
    def __init__(self, *, refresh_window=False):
        super().__init__()
        self.template,self.attribution=OSM,'© OpenStreetMap contributors'
        self.refresh_window=refresh_window
        self.z=11
        self.center=(31.2304,121.4737)
        self.marker=None
        self.favorites=[]
        self.show_favorites=True
        self.pin_hits=[]
        self.tiles=collections.OrderedDict()
        self.pending={}
        self.reload_urls=set()
        self.scheduler=C.QTimer(self)
        self.scheduler.setSingleShot(True)
        self.scheduler.timeout.connect(self.load_visible)
        self.wheel_delta=0
        self.failed={}
        self.press=None
        self.moved=False
        self.net=N.QNetworkAccessManager(self)
        directory=Path(C.QStandardPaths.writableLocation(C.QStandardPaths.CacheLocation))/'tiles'
        self.cache=None
        try:
            directory.mkdir(parents=True,exist_ok=True)
            if os.access(directory,os.W_OK):
                self.cache=N.QNetworkDiskCache(self)
                self.cache.setCacheDirectory(str(directory))
                self.cache.setMaximumCacheSize(96*1024**2)
                self.net.setCache(self.cache)
        except OSError:
            pass  # The in-memory cache also works in a read-only profile.
        self.setMinimumSize(320,280)

    def layer(self,template,attribution):
        self.template,self.attribution=template,attribution
        self.camera_changed()

    def schedule(self,delay=0):
        if self.isVisible() and (not self.scheduler.isActive() or self.scheduler.remainingTime()>delay):
            self.scheduler.start(delay)

    def refresh_viewport(self):
        """标记地图需要重绘；Android 同时从顶层窗口原点刷新整张显示表面。"""
        self.update()
        if self.refresh_window and self.isVisible():
            self.window().update()

    def camera_changed(self):
        self.refresh_viewport()
        self.schedule(16)

    def showEvent(self,event):
        super().showEvent(event)
        self.schedule()

    def resizeEvent(self,event):
        super().resizeEvent(event)
        self.camera_changed()

    def hideEvent(self,event):
        self.scheduler.stop()
        self.cancel_except(set())
        super().hideEvent(event)

    def cancel_except(self,visible):
        for url in list(self.pending):
            if url not in visible:
                reply=self.pending.pop(url)
                reply.abort()

    def visible_tiles(self):
        left,top=self.origin()
        count=2**self.z
        for x in range(math.floor(left/256),math.ceil((left+self.width())/256)):
            for y in range(max(0,math.floor(top/256)),min(count,math.ceil((top+self.height())/256))):
                box=C.QRect(round(256*x-left),round(256*y-top),256,256)
                yield self.template.format(z=self.z,x=x%count,y=y),x%count,y,box

    def refresh_tiles(self):
        visible={url for url,_,_,_ in self.visible_tiles()}
        self.reload_urls.update(visible)
        for url in visible:
            self.failed.pop(url,None)
        self.schedule()

    def load_visible(self):
        if not self.isVisible(): return
        center=self.rect().center()
        ordered=sorted(self.visible_tiles(),key=lambda tile:(tile[3].center()-center).manhattanLength())
        visible={tile[0] for tile in ordered}
        self.cancel_except(visible)
        self.reload_urls.intersection_update(visible)
        now=time.monotonic()
        next_retry=None
        for url,_,_,_ in ordered:
            if url in self.tiles:
                self.tiles.move_to_end(url)
                if url not in self.reload_urls: continue
            if url in self.pending: continue
            deadline=self.failed.get(url,(0,0))[0]
            if deadline>now:
                next_retry=min(next_retry,deadline) if next_retry is not None else deadline
            elif len(self.pending)<4:
                self.fetch(url)
        if next_retry is not None:
            self.schedule(max(1,math.ceil((next_retry-now)*1000)))

    def fetch(self,url):
        r=request(url)
        if url in self.reload_urls:
            r.setAttribute(N.QNetworkRequest.CacheLoadControlAttribute,N.QNetworkRequest.AlwaysNetwork)
        elif self.cache is not None:
            expires=self.cache.metaData(r.url()).expirationDate()
            if expires.isValid() and expires>C.QDateTime.currentDateTimeUtc():
                r.setAttribute(N.QNetworkRequest.CacheLoadControlAttribute,N.QNetworkRequest.PreferCache)
        reply=self.net.get(r)
        self.pending[url]=reply
        def finished():
            reply.deleteLater()
            if self.pending.get(url) is not reply: return
            del self.pending[url]
            tile=G.QImage()
            success=reply.error()==N.QNetworkReply.NoError
            if success and tile.loadFromData(reply.readAll()):
                self.tiles[url]=tile
                self.tiles.move_to_end(url)
                self.failed.pop(url,None)
                self.reload_urls.discard(url)
                capacity=max(200,(math.ceil(self.width()/256)+1)*(math.ceil(self.height()/256)+1))
                if len(self.tiles)>capacity: self.tiles.popitem(last=False)
            else:
                if success and self.cache:
                    self.cache.remove(C.QUrl(url))
                delay=min(60,max(2,self.failed.get(url,(0,0))[1]*2))
                retry=bytes(reply.rawHeader('Retry-After'))
                if retry.isdigit():
                    delay=max(delay,min(86400,int(retry)))
                reason='响应不是有效地图图片' if success else reply.errorString()
                self.failed[url]=(time.monotonic()+delay,delay,reason)
                if len(self.failed)>512: self.failed.pop(next(iter(self.failed)))
            # 使用控件当前视口刷新，Qt 会合并同一轮事件中的瓦片更新。
            self.refresh_viewport()
            self.schedule()
        reply.finished.connect(finished)

    def origin(self):
        x,y=project(*self.center,self.z)
        return x-self.width()/2,y-self.height()/2

    def paintEvent(self,event):
        p=G.QPainter(self)
        dark=self.palette().color(G.QPalette.Window).lightness()<128
        # 底图在局部逻辑像素画布上拼接，Android 高 DPI 窗口只负责最终合成。
        surface=G.QImage(self.size(),G.QImage.Format_RGB32)
        surface.fill(G.QColor('#202637' if dark else '#e9edf0'))
        tiles_painter=G.QPainter(surface)
        left,top=self.origin()
        count=2**self.z
        failure_reason=None
        ready=total=0
        for url,x,y,box in self.visible_tiles():
            total+=1
            if failure_reason is None and url in self.failed:
                failure_reason=self.failed[url][2]
            if url in self.tiles:
                ready+=1
                tile=self.tiles[url]
                tiles_painter.drawImage(box,tile,tile.rect())
            else:
                tiles_painter.setPen(G.QColor('#2b3245' if dark else '#dbe2e7'))
                tiles_painter.drawRect(box)
                self.paint_cached_zoom(tiles_painter,x,y,box)
        tiles_painter.end()
        p.drawImage(self.rect(),surface,surface.rect())
        self.pin_hits.clear()
        if self.show_favorites:
            p.setRenderHint(G.QPainter.Antialiasing)
            for name,lat,lon in self.favorites:
                if self.marker and all(abs(v-w)<1e-7 for v,w in zip(self.marker,(lat,lon))): continue
                x,y=project(lat,lon,self.z)
                world=count*256
                x=(x-left-self.width()/2+world/2)%world-world/2+self.width()/2
                rect=C.QRectF(x-12,y-top-12,24,24)
                if not rect.intersects(C.QRectF(self.rect())): continue
                p.setBrush(G.QColor('#32354a' if dark else '#ffffff'))
                p.setPen(G.QColor('#8075b9')); p.drawEllipse(rect)
                draw_symbol(p,rect.adjusted(5,5,-5,-5),'bookmark','#a99cf4' if dark else '#6859b9')
                self.pin_hits.append((rect,name,lat,lon))
        if self.marker:
            x,y=project(*self.marker,self.z)
            world=count*256
            dx=(x-left-self.width()/2+world/2)%world-world/2
            p.setRenderHint(G.QPainter.Antialiasing)
            p.save()
            p.translate(dx+self.width()/2,y-top)
            path=G.QPainterPath(C.QPointF(0,0))
            path.cubicTo(-2,-6,-13,-13,-13,-22)
            path.cubicTo(-13,-39,13,-39,13,-22)
            path.cubicTo(13,-13,2,-6,0,0)
            p.setPen(G.QPen(G.QColor('white'),1.5))
            p.setBrush(G.QColor('#f59131'))
            p.drawPath(path)
            p.setPen(C.Qt.NoPen); p.setBrush(G.QColor('white'))
            p.drawEllipse(C.QPointF(0,-22),4,4)
            p.restore()
        label=self.attribution
        if failure_reason:
            budget=max(0,self.width()-p.fontMetrics().horizontalAdvance(label)-24)
            status=p.fontMetrics().elidedText('底图加载失败 · '+failure_reason,C.Qt.ElideRight,budget)
            label=status+'    '+label
        elif ready<total:
            label=f'加载 {ready}/{total}   '+label
        p.setPen(G.QColor('#e0e2ed' if dark else '#27343a'))
        w=p.fontMetrics().horizontalAdvance(label)+12
        p.fillRect(self.width()-w,self.height()-22,w,22,G.QColor('#303747' if dark else '#fafafa'))
        p.drawText(self.width()-w+5,self.height()-6,label)

    def paint_cached_zoom(self,p,x,y,box):
        # Only reuse neighboring zoom levels from the current source; never fetch a preview.
        p.save()
        p.setRenderHint(G.QPainter.SmoothPixmapTransform)
        for depth in range(1,min(3,self.z)+1):
            scale=2**depth
            parent=self.tiles.get(self.template.format(z=self.z-depth,x=x//scale,y=y//scale))
            if parent is not None:
                w,h=parent.width()/scale,parent.height()/scale
                src=C.QRectF(x%scale*w,y%scale*h,w,h)
                p.drawImage(C.QRectF(box),parent,src)
                break
        for dx in (0,1):
            for dy in (0,1):
                child=self.tiles.get(self.template.format(z=self.z+1,x=2*x+dx,y=2*y+dy))
                if child is not None:
                    p.drawImage(C.QRect(box.x()+128*dx,box.y()+128*dy,128,128),child,child.rect())
        p.restore()

    def choose(self,coords,center=True,span=.05):
        self.marker=coords
        if center:
            self.center=coords
            latitude=coords[0]
            pixels=max(1,min(self.width(),self.height()*math.cos(math.radians(latitude))))
            self.z=max(1,min(19,round(math.log2(360*pixels/(256*span)))))
            self.camera_changed()
        else:
            self.refresh_viewport()

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
            self.center=unproject(x+self.width()/2-delta.x(),y+self.height()/2-delta.y(),self.z)
            self.camera_changed()

    def mouseReleaseEvent(self,event):
        if self.press is not None and not self.moved:
            for rect,name,lat,lon in reversed(self.pin_hits):
                if rect.contains(event.position()):
                    self.press=None
                    self.favorite_picked.emit(name,lat,lon)
                    return
            x,y=self.origin()
            coords=unproject(x+event.pos().x(),y+event.pos().y(),self.z)
            self.picked.emit(*coords)
        self.press=None

    def zoom(self,step,anchor=None):
        target=max(1,min(19,self.z+step))
        if target==self.z: return
        if anchor is not None:
            left,top=self.origin()
            scale=2**(target-self.z)
            x=(left+anchor.x())*scale+self.width()/2-anchor.x()
            y=(top+anchor.y())*scale+self.height()/2-anchor.y()
            self.center=unproject(x,y,target)
        self.z=target
        self.camera_changed()

    def wheelEvent(self,event):
        # High-resolution wheels emit fractions of a 120-unit detent.
        self.wheel_delta+=event.angleDelta().y()
        steps=math.trunc(self.wheel_delta/120)
        if steps:
            self.wheel_delta-=steps*120
            self.zoom(steps,event.position())
        event.accept()
