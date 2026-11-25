"""Qt widgets for the mode chooser and the map inspector."""
from PySide6 import QtCore as C, QtGui as G, QtWidgets as W


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
        QWidget#inspector, QTabWidget::pane {{ background: {surface}; }}
        QLabel#heading {{ font-size: 22px; font-weight: 650; }}
        QLabel#caption {{ color: {muted}; font-weight: 600; }}
        QPushButton, QToolButton, QComboBox, QLineEdit {{
            color: {text}; background: {surface}; border: 1px solid {border};
            border-radius: 8px; padding: 7px 10px;
        }}
        QComboBox {{ background: {inset}; padding-right: 26px; }}
        QComboBox::drop-down {{ border: none; width: 24px; }}
        QComboBox::down-arrow {{ image: none; }}
        QPushButton:hover, QComboBox:hover, QToolButton:hover, QLineEdit:focus {{ border-color: #8171d2; }}
        QPushButton:pressed, QToolButton:pressed {{ background: {inset}; }}
        QPushButton#primary, QTabBar::tab:selected {{
            background: #5746ae; color: white; border: 1px solid #5746ae;
        }}
        QPushButton#modeCard {{ text-align: left; padding: 20px; font-size: 17px; font-weight: 600; }}
        QPushButton#deviceCard {{ text-align: left; background: {inset}; font-weight: 600; }}
        QPushButton:disabled, QPushButton#primary:disabled {{ color: {muted}; background: {inset}; border-color: {border}; }}
        QTabWidget::pane {{ border: 0; }}
        QTabBar::tab {{ background: {inset}; color: {muted}; border-radius: 7px; padding: 7px 14px; margin: 2px; }}
        QPlainTextEdit {{ background: {inset}; color: {text}; border: 1px solid {border}; border-radius: 8px; padding: 6px; }}
        QCheckBox {{ spacing: 8px; }}
    """)
