# 声学雷达大屏启动器：自动拉起接收服务+音频桥，用原生窗口（WebView2）全屏显示网页
import subprocess, sys, time, os, urllib.request
from pathlib import Path

def app_dir():
    """exe 所在目录（PyInstaller onefile 的 __file__ 在临时解包目录，不能用它定位）。"""
    if getattr(sys, 'frozen', False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent

ROOT = app_dir()                                # exe 所在目录（或源码目录）
PC = ROOT / 'pc_rx' / 'pc'
URL = 'http://127.0.0.1:8768'

def find_python():
    # exe 打包后 sys.executable 是 exe 自己；后台服务仍需系统 Python
    for cmd in ('python', 'py'):
        try:
            subprocess.check_output([cmd, '-c', 'import sys'], timeout=5)
            return cmd
        except Exception:
            continue
    return None

def wait_server(timeout=25):
    t0 = time.time()
    while time.time() - t0 < timeout:
        try:
            urllib.request.urlopen(URL + '/api/state', timeout=2)
            return True
        except Exception:
            time.sleep(0.5)
    return False

def main():
    py = find_python()
    if not py:
        import tkinter.messagebox as mb
        mb.showerror('声学雷达', '未找到 Python，请先安装 Python 3.9+ 并勾选 Add to PATH')
        return
    env = dict(os.environ, VP_DIR=str(ROOT / 'voiceprint'))
    # 已运行则不重复启动
    if not wait_server(2):
        subprocess.Popen([py, '-B', str(PC / 'web_receiver.py')], env=env,
                         creationflags=subprocess.CREATE_NEW_CONSOLE)
        subprocess.Popen([py, '-B', str(PC / 'jtag_audio_bridge.py')], env=env,
                         creationflags=subprocess.CREATE_NEW_CONSOLE)
        wait_server(25)
    import webview
    webview.create_window('声学雷达大屏', URL, fullscreen=True)
    webview.start()

if __name__ == '__main__':
    main()
