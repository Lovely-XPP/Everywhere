"""Qt widgets for the mode chooser and the map inspector."""
from PySide6 import QtCore as C, QtGui as G, QtWidgets as W


def mode_icon(bluetooth):
    image = G.QPixmap(64, 64)
    image.fill(C.Qt.transparent)
    painter = G.QPainter(image)
    painter.scale(2, 2)
    painter.setRenderHint(G.QPainter.Antialiasing)
    painter.setPen(C.Qt.NoPen)
    painter.setBrush(G.QColor('#6152b2' if bluetooth else '#237781'))
    painter.drawRoundedRect(C.QRectF(0, 0, 32, 32), 9, 9)
    painter.setPen(G.QPen(G.QColor('white'), 1.6, C.Qt.SolidLine, C.Qt.RoundCap, C.Qt.RoundJoin))
    if bluetooth:
        points = [(10,11),(21,21),(16,26),(16,6),(21,11),(10,21)]
        painter.drawPolyline([C.QPointF(x,y) for x,y in points])
    else:
        painter.setBrush(C.Qt.NoBrush)
        painter.drawRoundedRect(C.QRectF(10,5,12,22), 2, 2)
        painter.drawLine(14,23,18,23)
    painter.end()
    image.setDevicePixelRatio(2)
    return image


class ModeCard(W.QPushButton):
    """An accessible keyboard-activated card with separate title and description."""
    def __init__(self, title, detail, bluetooth=False):
        super().__init__()
        self.setAccessibleName(title)
        self.setAccessibleDescription(detail)
        self.setObjectName('modeCard')
        self.setMinimumHeight(144)
        layout = W.QGridLayout(self)
        layout.setContentsMargins(22,18,22,18)
        glyph = W.QLabel()
        glyph.setPixmap(mode_icon(bluetooth))
        layout.addWidget(glyph,0,0)
        arrow = W.QLabel('›')
        arrow.setAlignment(C.Qt.AlignRight)
        layout.addWidget(arrow,0,1)
        for row, name, text in ((1,'modeTitle',title), (2,'modeDetail',detail)):
            label = W.QLabel(text)
            label.setObjectName(name)
            layout.addWidget(label,row,0,1,2)
        for label in self.findChildren(W.QLabel):
            label.setAttribute(C.Qt.WA_TransparentForMouseEvents)


class Dropdown(W.QComboBox):
    """Keep native popup navigation and draw the same compact chevron as the Mac inspector."""
    def paintEvent(self, event):
        super().paintEvent(event)
        painter = G.QPainter(self)
        painter.setRenderHint(G.QPainter.Antialiasing)
        painter.setPen(G.QPen(self.palette().color(G.QPalette.Text), 1.5))
        x, y = self.width() - 15, self.height() / 2
        painter.drawPolyline([C.QPointF(x-4, y-2), C.QPointF(x, y+2), C.QPointF(x+4, y-2)])


def style(window):
    dark = window.palette().color(G.QPalette.Window).lightness() < 128
    surface, inset, text, muted, border = (
        ('#232840', '#30344d', '#f1f1fc', '#bfc2d4', '#484c65') if dark else
        ('#ffffff', '#f0f0fa', '#26273b', '#595c73', '#d6d7e6'))
    window.setStyleSheet(f"""
        QMainWindow, QWidget#chooser {{ background: {inset}; }}
        QWidget#inspector, QWidget#inspector QWidget {{ color: {text}; }}
        QWidget#inspector, QWidget#inspectorPage, QTabWidget::pane {{ background: {surface}; }}
        QLabel#heading {{ font-size: 22px; font-weight: 650; }}
        QLabel#caption {{ color: {muted}; font-weight: 600; }}
        QPushButton, QToolButton, QComboBox, QLineEdit {{
            color: {text}; background: {surface}; border: 1px solid {border};
            border-radius: 8px; padding: 7px 10px;
        }}
        QComboBox {{ background: {inset}; padding-right: 26px; }}
        QComboBox QAbstractItemView {{ background: {surface}; color: {text}; padding: 4px;
            border: 1px solid {border}; selection-background-color: #5746ae; selection-color: white; }}
        QComboBox::drop-down {{ border: none; width: 24px; }}
        QComboBox::down-arrow {{ image: none; }}
        QPushButton:hover, QComboBox:hover, QToolButton:hover, QLineEdit:focus {{ border-color: #8171d2; }}
        QPushButton:pressed, QToolButton:pressed {{ background: {inset}; }}
        QPushButton#primary, QTabBar::tab:selected {{
            background: #5746ae; color: white; border: 1px solid #5746ae;
        }}
        QPushButton#modeCard {{ text-align: left; padding: 20px; font-size: 17px; font-weight: 600; }}
        QPushButton#modeCard:focus, QPushButton:focus, QComboBox:focus {{ border-color: #8171d2; }}
        QLabel#modeTitle {{ font-size: 20px; font-weight: 650; color: {text}; }}
        QLabel#modeDetail {{ font-size: 13px; color: {muted}; }}
        QPushButton#deviceCard {{ text-align: left; background: {inset}; font-weight: 600; }}
        QPushButton:disabled, QPushButton#primary:disabled {{ color: {muted}; background: {inset}; border-color: {border}; }}
        QTabWidget::pane {{ border: 0; }}
        QTabBar::tab {{ background: {inset}; color: {muted}; border-radius: 7px; padding: 7px 14px; margin: 2px; }}
        QPlainTextEdit {{ background: {inset}; color: {text}; border: 1px solid {border}; border-radius: 8px; padding: 6px; }}
        QCheckBox {{ spacing: 8px; }}
    """)
