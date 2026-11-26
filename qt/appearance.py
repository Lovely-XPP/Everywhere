"""Swift PlaceKit colors, scalable symbols and controls shared by the Qt desktop views."""
from PySide6 import QtCore as C, QtGui as G, QtWidgets as W


def dark_mode():
    return W.QApplication.palette().color(G.QPalette.Window).lightness() < 128


# Geometry is expressed on a 24-point canvas so icons retain their stroke at any DPI.
LINES = {
    'location': [[(3,11),(21,3),(14,21),(11,13),(3,11)]],
    'arrow': [[(4,12),(20,12)],[(14,6),(20,12),(14,18)]],
    'next': [[(9,5),(16,12),(9,19)]], 'down': [[(5,9),(12,16),(19,9)]],
    'up': [[(5,15),(12,8),(19,15)]], 'check': [[(4,12),(9,17),(20,6)]],
    'map': [[(2,5),(8,3),(16,6),(22,3),(22,19),(16,22),(8,19),(2,21),(2,5)],[(8,3),(8,19)],[(16,6),(16,22)]],
    'layers': [[(2,8),(12,3),(22,8),(12,13),(2,8)],[(3,12),(12,17),(21,12)],[(3,16),(12,21),(21,16)]],
    'wave': [[(1,13),(6,13),(9,5),(13,20),(16,11),(19,13),(23,13)]],
    'device': [[(3,15),(6,7),(18,7),(21,15),(21,18),(3,18),(3,15),(21,15)]],
    'phone': [[(8,3),(16,3),(17,4),(17,20),(16,21),(8,21),(7,20),(7,4),(8,3)],[(10,18),(14,18)]],
    'laptop': [[(4,16),(4,5),(20,5),(20,16),(4,16)],[(1,19),(23,19)]],
    'cable': [[(8,2),(8,7)],[(16,2),(16,7)],[(6,7),(18,7),(18,12),(15,15),(9,15),(6,12),(6,7)],[(12,15),(12,22)]],
    'bookmark': [[(6,3),(18,3),(18,21),(12,16),(6,21),(6,3)]],
    'clock': [[(12,6),(12,12),(16,15)]], 'search': [[(15,15),(21,21)]],
    'radio': [[(12,12),(12,21)]], 'refresh': [[(20,3),(20,8),(15,8)]],
    'plus': [[(5,12),(19,12)],[(12,5),(12,19)]], 'minus': [[(5,12),(19,12)]],
}


def draw_symbol(p, rect, name, color):
    p.save()
    p.translate(rect.x(), rect.y())
    p.scale(rect.width()/24, rect.height()/24)
    p.setRenderHint(G.QPainter.Antialiasing)
    p.setPen(G.QPen(G.QColor(color),1.7,C.Qt.SolidLine,C.Qt.RoundCap,C.Qt.RoundJoin))
    p.setBrush(G.QColor(color) if name=='location' else C.Qt.NoBrush)
    for line in LINES.get(name, []):
        p.drawPolyline([C.QPointF(x,y) for x,y in line])
        if name=='location': p.drawPolygon([C.QPointF(x,y) for x,y in line])
    if name=='radio':
        for r in (6,10):
            box=C.QRectF(12-r,10-r,2*r,2*r)
            for start in (-45,135): p.drawArc(box,start*16,90*16)
        p.setBrush(G.QColor(color)); p.drawEllipse(C.QPointF(12,10),1.5,1.5)
    if name=='wifi':
        for r in (6,11,16): p.drawArc(C.QRectF(12-r,20-r,2*r,2*r),48*16,84*16)
        p.setBrush(G.QColor(color)); p.drawEllipse(C.QPointF(12,20),1.4,1.4)
    if name=='search': p.drawEllipse(C.QRectF(3,3,14,14))
    if name=='clock': p.drawEllipse(C.QRectF(3,3,18,18))
    if name=='refresh': p.drawArc(C.QRectF(4,4,16,16),55*16,310*16)
    p.restore()


class SymbolEngine(G.QIconEngine):
    def __init__(self,name,tint=None):
        super().__init__()
        self.name,self.tint=name,tint

    def clone(self):
        return SymbolEngine(self.name,self.tint)

    def paint(self,p,rect,mode,state):
        color=self.tint or ('#c7c9df' if dark_mode() else '#616178')
        if mode==G.QIcon.Disabled: color='#9293a5'
        draw_symbol(p,rect,self.name,color)

    def pixmap(self,size,mode,state):
        image=G.QPixmap(size)
        image.fill(C.Qt.transparent)
        p=G.QPainter(image)
        self.paint(p,image.rect(),mode,state)
        p.end()
        return image


def icon(name,tint=None):
    return G.QIcon(SymbolEngine(name,tint))


class Symbol(W.QWidget):
    def __init__(self,name,size,tint=None,badge=False):
        super().__init__()
        self.name,self.tint,self.badge=name,tint,badge
        self.setFixedSize(size,size)
        self.setAttribute(C.Qt.WA_TransparentForMouseEvents)

    def paintEvent(self,event):
        p=G.QPainter(self)
        p.setRenderHint(G.QPainter.Antialiasing)
        box=C.QRectF(self.rect())
        if self.badge:
            gradient=G.QLinearGradient(box.topLeft(),box.bottomRight())
            gradient.setColorAt(0,G.QColor('#8172e6')); gradient.setColorAt(1,G.QColor('#513dbd'))
            p.setBrush(gradient); p.setPen(C.Qt.NoPen); p.drawRoundedRect(box,9,9)
            box=box.adjusted(7,7,-7,-7)
        draw_symbol(p,box,self.name,self.tint or ('#f0eff9' if dark_mode() else '#53536a'))


def label(text,role='',wrap=False):
    w=W.QLabel(text)
    w.setTextFormat(C.Qt.PlainText)
    w.setObjectName(role)
    w.setWordWrap(wrap)
    return w


class ModeCard(W.QPushButton):
    def __init__(self,title,detail,bluetooth=False):
        super().__init__()
        self.setAccessibleName(title)
        self.setAccessibleDescription(detail)
        self.setCursor(C.Qt.PointingHandCursor)
        self.setObjectName('bluetoothCard' if bluetooth else 'softwareCard')
        self.setFixedHeight(176)
        self.setSizePolicy(W.QSizePolicy.Expanding,W.QSizePolicy.Fixed)
        tint='#6761d5' if bluetooth else '#229b9c'
        layout=W.QVBoxLayout(self)
        layout.setContentsMargins(24,24,24,24)
        layout.setSpacing(10)
        layout.addWidget(Symbol('radio' if bluetooth else 'cable',32,tint))
        layout.addStretch()
        row=W.QHBoxLayout()
        row.addWidget(label(title,'modeTitle')); row.addStretch()
        row.addWidget(Symbol('arrow',20,tint))
        layout.addLayout(row)
        layout.addWidget(label(detail,'modeDetail'))
        for child in self.findChildren(W.QWidget): child.setAttribute(C.Qt.WA_TransparentForMouseEvents)


class ElidingLabel(W.QLabel):
    """Keep user-supplied place names within their allocated width."""
    def __init__(self, role=''):
        super().__init__()
        self.setObjectName(role)
        self.setSizePolicy(W.QSizePolicy.Ignored,W.QSizePolicy.Preferred)

    def setText(self,text):
        super().setText(text)
        self.setToolTip(text)

    def paintEvent(self,event):
        painter=G.QPainter(self)
        painter.setPen(self.palette().color(G.QPalette.WindowText))
        rect=self.contentsRect()
        painter.drawText(rect,C.Qt.AlignLeft | C.Qt.AlignVCenter,
                         self.fontMetrics().elidedText(self.text(),C.Qt.ElideRight,rect.width()))


class Switch(W.QCheckBox):
    def hitButton(self,pos):
        return self.rect().contains(pos)

    def paintEvent(self,event):
        p=G.QPainter(self)
        p.setRenderHint(G.QPainter.Antialiasing)
        if not self.isEnabled(): p.setOpacity(.5)
        ink='#f3f2fa' if dark_mode() else '#242437'
        p.setPen(G.QColor(ink))
        p.drawText(self.rect().adjusted(0,0,-40,0),C.Qt.AlignLeft|C.Qt.AlignVCenter,self.text())
        box=C.QRectF(self.width()-33,(self.height()-19)/2,32,19)
        p.setPen(C.Qt.NoPen)
        p.setBrush(G.QColor('#6756ca' if self.isChecked() else '#828395'))
        p.drawRoundedRect(box,9.5,9.5)
        p.setBrush(G.QColor('white'))
        p.drawEllipse(C.QRectF(box.x()+(16 if self.isChecked() else 3),box.y()+3,13,13))
        if self.hasFocus() and self.testAttribute(C.Qt.WA_KeyboardFocusChange):
            p.setBrush(C.Qt.NoBrush); p.setPen(G.QColor('#8174cd'))
            p.drawRoundedRect(self.rect().adjusted(0,0,-1,-1),4,4)


class DropdownRows(W.QStyledItemDelegate):
    """The checkmark follows the committed value while the highlight follows navigation."""
    title_role=C.Qt.UserRole+1
    detail_role=C.Qt.UserRole+2

    def __init__(self,field):
        super().__init__(field)
        self.field=field

    def sizeHint(self,option,index):
        title=index.data(self.title_role) or index.data() or ''
        detail=index.data(self.detail_role) or ''
        metrics=G.QFontMetrics(option.font)
        width=max(metrics.horizontalAdvance(title),metrics.horizontalAdvance(detail))+56
        return C.QSize(width,48 if detail else 34)

    def paint(self,p,option,index):
        p.save()
        p.setRenderHint(G.QPainter.Antialiasing)
        dark=dark_mode()
        chosen=index.row()==self.field.currentIndex()
        active=bool(option.state & (W.QStyle.State_Selected | W.QStyle.State_MouseOver))
        box=option.rect.adjusted(3,1,-3,-1)
        if active or chosen:
            fill=('#40395e' if dark else '#ebe8fb') if active else ('#303049' if dark else '#f5f3fc')
            p.setBrush(G.QColor(fill)); p.setPen(C.Qt.NoPen); p.drawRoundedRect(box,7,7)
        accent='#b0a3ff' if dark else '#6653be'
        title=index.data(self.title_role) or index.data() or ''
        detail=index.data(self.detail_role)
        area=box.adjusted(10,0,-30,0)
        font=G.QFont(option.font)
        font.setPixelSize(13)
        font.setWeight(G.QFont.DemiBold if chosen else G.QFont.Medium)
        p.setFont(font); p.setPen(G.QColor('#f1f0fa' if dark else '#28253d'))
        line=C.QRect(area.x(),area.y()+4,area.width(),21) if detail else area
        p.drawText(line,C.Qt.AlignVCenter,p.fontMetrics().elidedText(title,C.Qt.ElideMiddle,line.width()))
        if detail:
            font.setWeight(G.QFont.Normal); font.setPixelSize(11); p.setFont(font)
            p.setPen(G.QColor('#bbb8d1' if dark else '#676378'))
            line=C.QRect(area.x(),line.bottom(),area.width(),18)
            p.drawText(line,C.Qt.AlignVCenter,p.fontMetrics().elidedText(detail,C.Qt.ElideMiddle,line.width()))
        if chosen:
            draw_symbol(p,C.QRectF(box.right()-22,box.center().y()-7,15,15),'check',accent)
        p.restore()


class Dropdown(W.QComboBox):
    def __init__(self,title,symbol):
        super().__init__()
        self.symbol=symbol
        self.setAccessibleName(title)
        self.setFixedHeight(46)
        self.setFocusPolicy(C.Qt.StrongFocus)
        self.setSizePolicy(W.QSizePolicy.Ignored,W.QSizePolicy.Fixed)
        self.setCursor(C.Qt.PointingHandCursor)
        view=W.QListView()
        view.setObjectName('dropdownOptions')
        view.setHorizontalScrollBarPolicy(C.Qt.ScrollBarAlwaysOff)
        view.setVerticalScrollMode(W.QAbstractItemView.ScrollPerPixel)
        view.setMouseTracking(True)
        self.setView(view)
        popup=view.window()
        popup.setObjectName('dropdownPopup')
        popup.setAttribute(C.Qt.WA_TranslucentBackground)
        self.setItemDelegate(DropdownRows(self))
        self.setMaxVisibleItems(7)
        view.installEventFilter(self)

    def addDevice(self,name,identity,summary):
        self.addItem(summary,identity)
        index=self.count()-1
        self.setItemData(index,name,DropdownRows.title_role)
        self.setItemData(index,identity,DropdownRows.detail_role)
        self.setItemData(index,name+' · '+identity,C.Qt.ToolTipRole)

    def event(self,event):
        if event.type()==C.QEvent.ToolTip:
            text=self.currentData(C.Qt.ToolTipRole) or self.currentText() or self.placeholderText()
            if text: W.QToolTip.showText(event.globalPos(),text,self)
            return True
        return super().event(event)

    def eventFilter(self,obj,event):
        if event.type() in (C.QEvent.Show,C.QEvent.Hide):
            self.update()
        return super().eventFilter(obj,event)

    def showPopup(self):
        if not self.isEnabled() or not self.count(): return
        view=self.view()
        screen=self.screen().availableGeometry()
        content=min(410,view.sizeHintForColumn(0)+24)
        view.setMinimumWidth(min(screen.width()-12,max(self.width()-2,content)))
        super().showPopup()

    def keyPressEvent(self,event):
        if event.key() in (C.Qt.Key_Space,C.Qt.Key_Return,C.Qt.Key_Enter,C.Qt.Key_Down,C.Qt.Key_Up):
            self.showPopup()
        elif (event.text().isprintable() and event.text() and
              not event.modifiers() & (C.Qt.ControlModifier|C.Qt.MetaModifier)) or event.key() in (C.Qt.Key_Home,C.Qt.Key_End,C.Qt.Key_PageUp,C.Qt.Key_PageDown):
            self.showPopup()
            if self.view().isVisible(): W.QApplication.sendEvent(self.view(),event)
        else:
            super().keyPressEvent(event)

    def wheelEvent(self,event):
        # Scrolling the inspector past a device must not initiate a connection.
        event.ignore()

    def paintEvent(self,event):
        p=G.QPainter(self)
        p.setRenderHint(G.QPainter.Antialiasing)
        dark=dark_mode()
        opened=self.view().isVisible()
        focused=self.hasFocus() and self.testAttribute(C.Qt.WA_KeyboardFocusChange)
        active=self.isEnabled() and (opened or focused or self.underMouse())
        if not self.isEnabled(): p.setOpacity(.6)
        accent='#ad9cfa' if dark else '#6753ba'
        muted='#bab8ce' if dark else '#696679'
        box=C.QRectF(self.rect()).adjusted(1,1,-1,-1)
        p.setBrush(G.QColor(('#333249' if dark else '#f2f0fb') if active else ('#2c2e43' if dark else '#f5f5fc')))
        p.setPen(G.QPen(G.QColor(accent if active else ('#49465d' if dark else '#d9d7e5')),1.5 if focused or opened else 1))
        p.drawRoundedRect(box,10,10)
        badge=C.QRectF(10,(self.height()-26)/2,26,26)
        p.setBrush(G.QColor('#403852' if dark else '#eae5f8')); p.setPen(C.Qt.NoPen)
        p.drawRoundedRect(badge,7,7)
        draw_symbol(p,badge.adjusted(5,5,-5,-5),self.symbol,accent)
        draw_symbol(p,C.QRectF(self.width()-23,(self.height()-12)/2,12,12),'up' if opened else 'down',accent if active else muted)
        width=max(0,self.width()-73)
        font=self.font()
        font.setPixelSize(11); p.setFont(font); p.setPen(G.QColor(muted))
        p.drawText(C.QRect(44,4,width,17),C.Qt.AlignVCenter,p.fontMetrics().elidedText(self.accessibleName(),C.Qt.ElideRight,width))
        font.setPixelSize(13); font.setWeight(G.QFont.DemiBold)
        p.setFont(font); p.setPen(G.QColor(('#f2f1fa' if dark else '#28253a') if self.currentIndex()>=0 else muted))
        value=self.currentText() or self.placeholderText()
        p.drawText(C.QRect(44,21,width,20),C.Qt.AlignVCenter,p.fontMetrics().elidedText(value,C.Qt.ElideMiddle,width))


class Segments(W.QTabBar):
    """Full-width segmented picker with native tab focus, selection and arrow-key navigation."""
    def __init__(self,items):
        super().__init__()
        self.setExpanding(True)
        self.setDrawBase(False)
        self.setUsesScrollButtons(False)
        self.setIconSize(C.QSize(15,15))
        self.setCursor(C.Qt.PointingHandCursor)
        for title,symbol,value in items:
            index=self.addTab(icon(symbol),title)
            self.setTabData(index,value)

    def tabSizeHint(self,index):
        return C.QSize(80,32)

    def paintEvent(self,event):
        p=W.QStylePainter(self)
        for i in range(self.count()):
            opt=W.QStyleOptionTab()
            self.initStyleOption(opt,i)
            p.drawControl(W.QStyle.CE_TabBarTabShape,opt)
            selected=i==self.currentIndex()
            font=self.font()
            font.setWeight(G.QFont.DemiBold if selected else G.QFont.Normal)
            p.setFont(font)
            dark=dark_mode()
            ink=('#f3f2fa' if dark else '#28263a') if selected else ('#bbbed0' if dark else '#616377')
            p.setPen(G.QColor(ink))
            if not self.isEnabled(): p.setOpacity(.55)
            title=self.tabText(i)
            width=p.fontMetrics().horizontalAdvance(title)
            rect=self.tabRect(i)
            x=rect.center().x()-(width+20)//2
            self.tabIcon(i).paint(p,C.QRect(x,rect.center().y()-7,15,15))
            p.drawText(C.QRect(x+20,rect.y(),width+2,rect.height()),C.Qt.AlignVCenter,title)
            p.setOpacity(1)
            if selected and self.hasFocus() and self.testAttribute(C.Qt.WA_KeyboardFocusChange):
                p.setBrush(C.Qt.NoBrush)
                p.setPen(G.QColor('#8174cd'))
                p.drawRoundedRect(rect.adjusted(1,1,-1,-1),8,8)


class DeviceRow(W.QStyledItemDelegate):
    """Swift's two-line transport row, with a trailing selection indicator."""
    def sizeHint(self,option,index):
        return C.QSize(160,52)

    def paint(self,p,option,index):
        p.save()
        dark=dark_mode()
        selected=bool(option.state & W.QStyle.State_Selected)
        accent='#a298fa' if dark else '#6453be'
        ink='#f3f2fa' if dark else '#242437'
        muted='#b7bacf' if dark else '#626476'
        box=C.QRectF(option.rect).adjusted(1,2,-1,-2)
        p.setRenderHint(G.QPainter.Antialiasing)
        p.setBrush(G.QColor(('#383450' if dark else '#ecebfc') if selected else ('#2b2f47' if dark else '#f6f6fd')))
        p.setPen(G.QColor(accent if selected else ('#3f435c' if dark else '#dcdde8')))
        p.drawRoundedRect(box,9,9)
        name,_,detail=index.data().partition('\n')
        draw_symbol(p,C.QRectF(box.left()+10,box.center().y()-9,18,18),'cable' if 'USB' in detail else 'wifi',accent)
        text=box.toRect().adjusted(38,4,-34,-4)
        font=option.font
        for i,(value,size,color) in enumerate(((name,13,ink),(detail,11,muted))):
            font.setPixelSize(size)
            font.setWeight(G.QFont.DemiBold if i==0 else G.QFont.Normal)
            p.setFont(font); p.setPen(G.QColor(color))
            line=C.QRect(text.x(),text.y()+i*20,text.width(),20)
            p.drawText(line,C.Qt.AlignVCenter,p.fontMetrics().elidedText(value,C.Qt.ElideRight,line.width()))
        center=C.QPointF(box.right()-16,box.center().y())
        p.setPen(G.QColor(accent if selected else muted))
        p.setBrush(G.QColor(accent) if selected else C.Qt.NoBrush)
        p.drawEllipse(center,7,7)
        if selected:
            p.setPen(G.QPen(G.QColor('white'),1.5))
            p.drawPolyline([center+C.QPointF(x,y) for x,y in [(-3,0),(-.5,2.5),(4,-3)]])
        p.restore()


class Destination(W.QFrame):
    def paintEvent(self,event):
        p=G.QPainter(self)
        p.setRenderHint(G.QPainter.Antialiasing)
        r=C.QRectF(self.rect())
        path=G.QPainterPath(); path.addRoundedRect(r,20,20)
        p.setClipPath(path)
        grad=G.QLinearGradient(r.topLeft(),r.topRight())
        for stop,color in [(0,'#17133b'),(.5,'#2b1f63'),(1,'#523dbd')]: grad.setColorAt(stop,G.QColor(color))
        p.fillPath(path,grad)
        center=C.QPointF(r.width()*.89,r.height()*.72)
        radius=min(r.width()*.21,r.height()*.6)
        p.setPen(G.QPen(G.QColor(255,255,255,36),.8))
        for i in range(1,6): p.drawEllipse(center,radius*i/3,radius*i/3)
        p.setPen(G.QPen(G.QColor(255,255,255,64),1,C.Qt.DotLine))
        p.drawLine(C.QPointF(center.x(),0),C.QPointF(center.x(),r.height()))
        p.drawLine(C.QPointF(r.width()*.64,center.y()),C.QPointF(r.right(),center.y()))
        p.setPen(C.Qt.NoPen); p.setBrush(G.QColor('#ff962e')); p.drawEllipse(center,3,3)


def style(window):
    dark=dark_mode()
    wash,workspace,surface,inset,ink,muted,border,track=(
        ('#292546','#14182b','#232840','#30344d','#f3f2fa','#b7bacf','#3f435c','#303248') if dark else
        ('#e4e6ff','#f7f7ff','#ffffff','#eff0fc','#242437','#626476','#dcdde8','#e3e4ef'))
    window.setStyleSheet(f"""
    QWidget {{ color:{ink}; font-size:13px; }}
    QLabel {{ background:transparent; }}
    QWidget#chooser {{background:qlineargradient(x1:0,y1:0,x2:1,y2:1,stop:0 {wash},stop:1 {workspace});}}
    QWidget#inspector {{background:qlineargradient(x1:1,y1:0,x2:0,y2:1,stop:0 {wash},stop:0.52 {workspace},stop:1 {workspace});}}
    QScrollArea, QWidget#page, QWidget#qt_scrollarea_viewport {{background:transparent;border:0;}}
    QSplitter::handle {{background:{border};}}
    QFrame#panel,QFrame#footer {{background:{surface};border:1px solid {border};border-radius:15px;}}
    QLabel#chooserTitle {{font-size:32px;font-weight:600;}}
    QLabel#modeTitle,QLabel#destinationTitle {{font-size:21px;font-weight:700;}}
    QLabel#modeDetail,QLabel#muted {{color:{muted};}}
    QLabel#caption {{font-size:11px;color:{muted};}}
    QLabel#heading {{font-size:19px;font-weight:600;}}
    QLabel#panelTitle {{font-size:14px;font-weight:600;}}
    QWidget#destination QLabel {{color:white;}}
    QPushButton,QLineEdit,QPlainTextEdit,QListWidget {{background:{inset};border:1px solid {border};border-radius:9px;padding:6px 9px;}}
    QPushButton:hover,QPushButton:focus,QLineEdit:focus {{border-color:#8174cd;}}
    QPushButton:pressed {{background:{track};}}
    QPushButton#bluetoothCard,QPushButton#softwareCard {{background:{surface};border-radius:20px;padding:0;}}
    QPushButton#bluetoothCard {{border:1px solid #8984bc;}} QPushButton#softwareCard {{border:1px solid #79a8a9;}}
    QPushButton#bluetoothCard:hover,QPushButton#bluetoothCard:focus {{border:2px solid #7364cb;}}
    QPushButton#softwareCard:hover,QPushButton#softwareCard:focus {{border:2px solid #359695;}}
    QPushButton#deviceCard {{background:{inset};border:1px solid #9288cc;border-radius:12px;text-align:left;padding:0;}}
    QPushButton#disclosure,QPushButton#searchPill {{text-align:left;}}
    QPushButton#searchPill {{background:transparent;border:0;color:{muted};font-weight:600;}}
    QPushButton#searchPill:focus {{background:{inset};}}
    QListWidget::item {{padding:8px;border-radius:7px;}}
    QListWidget::item:selected {{background:#6355b9;color:white;}}
    QListWidget#softwareDevices {{background:transparent;border:0;padding:0;}}
    QFrame#segments {{background:{track};border-radius:12px;}}
    QTabBar::tab {{background:transparent;color:{muted};border:1px solid transparent;border-radius:9px;padding:0px 2px;}}
    QTabBar::tab:selected {{background:{surface};color:{ink};font-weight:600;}}
    QTabBar::tab:focus {{border:1px solid #8174cd;}}
    QPushButton#primary,QPushButton#secondary {{font-weight:600;border-radius:13px;min-height:23px;padding:7px;}}
    QPushButton#primary {{background:qlineargradient(x1:0,y1:0,x2:1,y2:0,stop:0 #523dbd,stop:1 #6648c2);color:white;}}
    QPushButton:disabled,QPushButton#primary:disabled,QPushButton#secondary:disabled {{color:{muted};background:{track};border-color:{track};}}
    QFrame#mapTools {{background:{surface};border:1px solid {border};border-radius:23px;}}
    QFrame#mapTools QLineEdit,QPushButton#mapIcon {{background:transparent;border:0;}}
    QFrame#mapTools QLineEdit:focus,QPushButton#mapIcon:focus {{background:{inset};border-radius:12px;}}
    QFrame#separator {{background:{border};}}
    Dropdown {{combobox-popup:0;background:transparent;border:0;padding:0;}}
    QFrame#dropdownPopup {{background:transparent;border:0;}}
    QListView#dropdownOptions {{background:{surface};border:1px solid {border};border-radius:9px;padding:3px;outline:0;}}
    Dropdown::drop-down {{border:none;width:0;}} Dropdown::down-arrow {{image:none;}}
    QAbstractItemView {{background:{surface};color:{ink};selection-background-color:#6355b9;selection-color:white;}}
    QWidget#modalBackdrop {{background:rgba(18,17,38,83);}}
    QDialog#consoleDialog,QFileDialog {{background:qlineargradient(x1:0,y1:0,x2:1,y2:1,stop:0 {wash},stop:.55 {workspace},stop:1 {workspace});}}
    QLabel#dialogTitle {{font-size:21px;font-weight:650;}}
    QFrame#dialogPanel {{background:{surface};border:1px solid {border};border-radius:14px;}}
    QLabel#dialogMessage {{font-size:14px;font-weight:500;}}
    QLineEdit#dialogField {{min-height:22px;border-radius:8px;}}
    QPushButton#dialogPrimary,QPushButton#dialogCancel,QPushButton#dialogDestructive {{min-height:20px;min-width:56px;padding:6px 14px;font-weight:600;border-radius:9px;}}
    QPushButton#dialogPrimary {{background:#6551bd;border:1px solid #6655b5;color:white;}}
    QPushButton#dialogPrimary:hover {{background:#5947af;}}
    QPushButton#dialogPrimary:disabled {{background:{track};border-color:{border};color:{muted};}}
    QPushButton#dialogDestructive {{background:#a13b4c;color:white;border:1px solid #aa4252;}}
    QPushButton#dialogDestructive:hover {{background:#8e3040;}}
    QPushButton#dialogCancel:focus,QPushButton#dialogPrimary:focus,QPushButton#dialogDestructive:focus {{border:2px solid #9584df;padding:5px 13px;}}
    QPushButton#dialogQuiet {{color:{muted};background:transparent;border:0;}}
    QPushButton#dialogQuiet:hover,QPushButton#dialogQuiet:focus {{background:{inset};}}
    QFileDialog QComboBox {{background:{inset};border:1px solid {border};border-radius:8px;padding:5px 8px;}}
    QFileDialog QTreeView,QFileDialog QListView {{background:{surface};border:1px solid {border};border-radius:9px;padding:4px;}}
    QFileDialog QHeaderView::section {{background:{inset};color:{muted};padding:5px;border:0;}}
    QFileDialog QToolButton {{border:1px solid transparent;border-radius:7px;padding:4px;}}
    QFileDialog QToolButton:hover {{background:{inset};border-color:{border};}}
    QCheckBox {{spacing:8px;}}
    QScrollBar:vertical {{background:transparent;width:7px;}} QScrollBar::handle:vertical {{background:{border};min-height:22px;border-radius:3px;}}
    QScrollBar::add-line:vertical,QScrollBar::sub-line:vertical {{height:0;}}
    """)
