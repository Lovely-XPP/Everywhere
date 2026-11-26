"""Windows 图形程序入口，打包自检时把启动异常和阻塞线程写入构建日志。"""
from contextlib import redirect_stderr, redirect_stdout
import faulthandler
import os
import sys
import traceback


def launch():
    """在调用时导入 Qt，以便自检日志覆盖模块加载阶段。"""
    from app import dispatch
    return dispatch()


if __name__ == '__main__':
    log_path = os.environ.get('EVERYWHERE_SMOKE_LOG')
    if sys.argv[1:2] == ['--smoke-test'] and log_path:
        with open(log_path, 'w', encoding='utf-8', buffering=1) as log, redirect_stdout(log), redirect_stderr(log):
            print('Importing the packaged Qt application')
            faulthandler.dump_traceback_later(60, file=log)
            try:
                result = launch()
            except Exception:
                traceback.print_exc()
                result = 1
            finally:
                faulthandler.cancel_dump_traceback_later()
        sys.exit(result)
    sys.exit(launch())
