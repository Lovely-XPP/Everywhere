"""Application-modal windows shared by the Qt desktop console."""
from PySide6 import QtCore as C, QtWidgets as W
import sys

from appearance import Dropdown, Symbol, label


class ModalBackdrop(W.QWidget):
    def __init__(self,dialog):
        owner=dialog.parentWidget().window()
        super().__init__(owner)
        self.setObjectName('modalBackdrop')
        self.setAttribute(C.Qt.WA_StyledBackground)
        self.hide()
        owner.installEventFilter(self)
        dialog.installEventFilter(self)
        dialog.destroyed.connect(self.deleteLater)

    def eventFilter(self,watched,event):
        if watched is self.parentWidget():
            if event.type()==C.QEvent.Resize:
                self.setGeometry(self.parentWidget().rect())
        elif event.type()==C.QEvent.Show:
            self.setGeometry(self.parentWidget().rect())
            self.show()
            self.raise_()
        elif event.type()==C.QEvent.Hide:
            self.hide()
        return False


def configure_modal(dialog,title):
    dialog.setWindowTitle(title)
    dialog.setWindowModality(C.Qt.ApplicationModal)
    dialog.setWindowFlag(C.Qt.WindowContextHelpButtonHint,False)
    dialog.backdrop=ModalBackdrop(dialog)


class ModalDialog(W.QDialog):
    def __init__(self,parent,title,symbol):
        super().__init__(parent)
        configure_modal(self,title)
        self.setObjectName('consoleDialog')
        self.setMinimumWidth(390)
        self.resize(440,200)
        if sys.platform == 'android':
            width = max(240, parent.window().width() - 24)
            self.setMinimumWidth(min(390, width))
            self.resize(min(440, width), 200)
        self.shell=W.QVBoxLayout(self)
        self.shell.setContentsMargins(20,20,20,18)
        self.shell.setSpacing(16)
        header=W.QHBoxLayout()
        header.setSpacing(11)
        header.addWidget(Symbol(symbol,38,'white',True))
        header.addWidget(label(title,'dialogTitle',True),1)
        self.shell.addLayout(header)
        panel=W.QFrame()
        panel.setObjectName('dialogPanel')
        self.body=W.QVBoxLayout(panel)
        self.body.setContentsMargins(15,14,15,14)
        self.body.setSpacing(10)
        self.shell.addWidget(panel,1)

    def open(self):
        # QDialog.open() forces WindowModal. show() preserves ApplicationModal
        # and lets search replies and device discovery run in the main event loop.
        self.show()

    def actions(self,accept_text,cancel_text='取消',default_cancel=False,destructive=False):
        row=W.QHBoxLayout()
        row.setSpacing(8)
        row.addStretch()
        cancel=W.QPushButton(cancel_text)
        accept=W.QPushButton(accept_text)
        cancel.setObjectName('dialogCancel')
        accept.setObjectName('dialogDestructive' if destructive else 'dialogPrimary')
        for control in (cancel,accept):
            control.setCursor(C.Qt.PointingHandCursor)
            control.setAutoDefault(False)
            row.addWidget(control)
        cancel.clicked.connect(self.reject)
        accept.clicked.connect(self.accept)
        default=cancel if default_cancel else accept
        default.setDefault(True)
        if default_cancel: cancel.setFocus()
        self.shell.addLayout(row)
        return accept

    def run(self):
        self.resize(self.width(),self.sizeHint().height())
        try:
            return self.exec()==W.QDialog.Accepted
        finally:
            self.deleteLater()


def text_prompt(parent,title,caption,action,symbol,value='',placeholder=''):
    dialog=ModalDialog(parent,title,symbol)
    field=W.QLineEdit(value)
    field.setPlaceholderText(placeholder)
    field.setAccessibleName(caption)
    field.setObjectName('dialogField')
    heading=label(caption,'panelTitle',True)
    heading.setBuddy(field)
    dialog.body.addWidget(heading)
    dialog.body.addWidget(field)
    accept=dialog.actions(action)
    field.textChanged.connect(lambda text:accept.setEnabled(bool(text.strip())))
    accept.setEnabled(bool(value.strip()))
    field.selectAll()
    field.setFocus()
    return field.text().strip() if dialog.run() else None


def confirm(parent,title,message,action,*,detail='',symbol='phone',cancel='取消',destructive=False):
    dialog=ModalDialog(parent,title,symbol)
    dialog.body.addWidget(label(message,'dialogMessage',True))
    if detail: dialog.body.addWidget(label(detail,'muted',True))
    dialog.actions(action,cancel,default_cancel=True,destructive=destructive)
    return dialog.run()


DATUM_OPTIONS=(('WGS 84',False),('GCJ-02（大陆偏移底图）',True))


def datum_picker(title):
    field=Dropdown(title,'map')
    for text,value in DATUM_OPTIONS:
        field.addItem(text,value)
    field.setAccessibleDescription('OpenStreetMap 的两个选项均按 WGS 84 对齐。')
    return field


def custom_layer(parent,gcj=False):
    dialog=ModalDialog(parent,'自定义地图图层','layers')
    url=W.QLineEdit()
    url.setAccessibleName('XYZ 图层地址')
    url.setPlaceholderText('https://…/{z}/{x}/{y}.png')
    datum=datum_picker('底图坐标系')
    datum.setCurrentIndex(datum.findData(gcj))
    credit=W.QLineEdit()
    credit.setAccessibleName('地图提供方署名')
    for field in (url,credit):
        field.setObjectName('dialogField')
    dialog.body.addWidget(label('XYZ 图层地址','panelTitle'))
    dialog.body.addWidget(url)
    dialog.body.addWidget(label('使用基于 WGS 84 的 XYZ 底图，HTTPS 地址须包含 {z}、{x}、{y}。','caption',True))
    dialog.body.addWidget(datum)
    dialog.body.addWidget(label('地图提供方署名','panelTitle'))
    dialog.body.addWidget(credit)
    accept=dialog.actions('应用图层')
    def validate():
        template=url.text().strip()
        try:
            address=C.QUrl(template.format(z=1,x=1,y=1))
            valid=address.isValid() and address.scheme()=='https' and bool(address.host())
        except (ValueError,KeyError,IndexError,AttributeError):
            valid=False
        accept.setEnabled(bool(valid and all(k in template for k in ('{z}','{x}','{y}')) and credit.text().strip()))
    url.textChanged.connect(validate)
    credit.textChanged.connect(validate)
    validate()
    url.setFocus()
    return (url.text().strip(),credit.text().strip(),datum.currentData()) if dialog.run() else None


def choose_program(parent):
    dialog=W.QFileDialog(parent)
    dialog.setOption(W.QFileDialog.DontUseNativeDialog)
    configure_modal(dialog,'选择外部认证程序')
    dialog.setObjectName('programPicker')
    dialog.setFileMode(W.QFileDialog.ExistingFile)
    dialog.setAcceptMode(W.QFileDialog.AcceptOpen)
    dialog.setViewMode(W.QFileDialog.Detail)
    dialog.setNameFilter('所有文件 (*)')
    for role,text in [(W.QFileDialog.LookIn,'位置'),(W.QFileDialog.FileName,'文件名'),
                      (W.QFileDialog.FileType,'文件类型'),(W.QFileDialog.Accept,'选择程序'),
                      (W.QFileDialog.Reject,'取消')]:
        dialog.setLabelText(role,text)
    dialog.resize(680,440)
    try:
        if dialog.exec()==W.QDialog.Accepted and dialog.selectedFiles():
            return dialog.selectedFiles()[0]
        return None
    finally:
        dialog.deleteLater()
