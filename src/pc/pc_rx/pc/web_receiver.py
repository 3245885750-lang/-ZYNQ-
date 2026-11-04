"""PC-only UDP receiver and small browser view. No inference or generated data."""
import argparse, collections, json, os, socket, sys, tempfile, threading, time
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from radar_protocol import decode, ReceiverState, describe

PAGE=Path(__file__).resolve().parents[2]/'acoustic-radar.html'  # 网页端大屏页面
SIMPLE=Path(__file__).resolve().parents[2]/'acoustic-radar-simple.html'  # 保留的简洁版页面

# ---- 声纹识别（8 麦阵列波束成形音频 → CAM++ 预训练模型声纹库比对，真实推理，无模拟数据）----
# 音频来源：板端 PS 以 'AUD3' 二进制包随 UDP 9000 下发（魔数4B + seq u32LE + nsamp u16LE + int16 单声道 16kHz PCM）
# 声纹库目录：优先环境变量 VP_DIR（launcher.py 会设置），否则回退到本仓库的 src/pc/voiceprint
VP_DIR = Path(os.environ.get('VP_DIR', str(Path(__file__).resolve().parents[2] / 'voiceprint')))
vp_state = {'data': None, 'ts': 0.0}   # data: {name,id,score,ok,candidates[]}；None=当前无人声
audio_buf = collections.deque(maxlen=16000*12)  # 阵列音频环形缓冲（int16 样本，约 12 秒）
audio_lock = threading.Lock()
audio_rx = {'last': 0.0, 'seq': -1}    # 最近收到阵列音频包的时刻/序号
vp_engine = {'db': None, 'err': None}

def feed_audio(data):
    """解析 'AUD3' 音频包写入环形缓冲；不是音频包返回 False。"""
    import struct
    if len(data) < 10 or data[:4] != b'AUD3':
        return False
    import numpy as np
    seq, nsamp = struct.unpack('<IH', data[4:10])
    pcm = np.frombuffer(data[10:10+2*nsamp], dtype='<i2')
    if pcm.size != nsamp:
        return True  # 截断包，丢弃
    with audio_lock:
        audio_buf.extend(pcm.tolist())
    audio_rx['last'] = time.monotonic(); audio_rx['seq'] = seq
    return True

def grab_audio(seconds):
    """从环形缓冲取最近 seconds 秒音频（float32），样本不足返回 None。"""
    import numpy as np
    n = int(seconds*16000)
    with audio_lock:
        arr = np.asarray(audio_buf, dtype=np.float32)
    if arr.size < n:
        return None
    return arr[-n:] / 32768.0

def vp_get_db():
    """惰性加载 CAM++ 预训练声纹库；失败只记一次，不影响 UDP 接收主流程。"""
    if vp_engine['db'] is None and vp_engine['err'] is None:
        try:
            sys.path.insert(0, str(VP_DIR))
            from campplus_sv import CampplusDB
            vp_engine['db'] = CampplusDB(threshold=0.35)  # 相似度≥0.35 认库中人（实测交叉得分<0.25），否则“无该人员”
        except Exception as e:
            vp_engine['err'] = str(e)
            print('voiceprint disabled:', e, flush=True)
    return vp_engine['db']

def latch_to_res(latch):
    """锁定结果 → 下发字典：有人→显示此人；无人但已判定→无该人员；未判定→无该人员。
    conf：余弦相似度经 sigmoid 按阈值 0.40 校准的置信度（0~100），相似度本身不是概率。"""
    import math
    conf = 100.0/(1.0+math.exp(-15.0*(latch.get('score', 0.0)-0.35)))
    if latch.get('name'):
        return {'name': latch['name'], 'id': latch.get('id'),
                'score': latch.get('score', 0.0), 'ok': True, 'conf': conf,
                'candidates': latch.get('cands', [])}
    return {'name': None, 'score': latch.get('score', 0.0), 'ok': False, 'conf': conf,
            'candidates': latch.get('cands', [])}

def vp_worker(lock, upd, state):
    """0.5s 一轮：仅当类别检测为“说话”时，取阵列音频最近 2.5s 滑窗做声纹比对；
    其余任何类别（拍手/钢琴/安静等）一律下发 no_voice，网页显示“未识别到人声”。
    多窗多数表决 + 结果锁定（latch）：识别到某人后在其说话期间一直显示，
    单窗抖动不改变显示；人声但不是库中人员 → 无该人员。"""
    import numpy as np
    win = 2.5
    votes = collections.deque(maxlen=5)   # 最近 5 个滑窗判定：人名 / 'unknown'
    pend = collections.deque(maxlen=2)    # 首次亮名前的候选：连续两窗一致才采纳
    latch = {'name': None, 'cands': [], 'score': 0.0, 'decided': False}  # 当前锁定显示结果
    speech_t0 = 0.0                       # 本轮说话事件开始时刻（用于首窗对齐说话起点）
    was_speech = False
    while True:
        time.sleep(0.5)
        with lock:
            c = state.latest.get('classification')
            speech_now = bool(c) and not state.stale('classification') \
                and c[0].get('state') == 'event' and c[0].get('label') == 'speech'
        if speech_now and not was_speech:
            speech_t0 = time.monotonic()   # 说话起点
        was_speech = speech_now
        if not speech_now:
            votes.clear(); pend.clear(); latch.update(name=None, cands=[], score=0.0, decided=False)
            res = {'no_voice': True}
        elif time.monotonic()-audio_rx['last'] > 1.5:
            # 阵列音频断流（JTAG 桥卡死/板端停发）：缓冲是旧音频，不能继续打分，按无人声处理
            votes.clear(); pend.clear(); latch.update(name=None, cands=[], score=0.0, decided=False)
            res = {'no_voice': True}
        else:
            # 说话事件期间：绝不回 no_voice，未确认前一律“无该人员”
            if latch['decided']:
                d = grab_audio(win)
                if d is None:
                    d = grab_audio(1.0)
            else:
                # 首窗对齐说话起点：只取说话开始后的音频，不含之前的安静段
                d = grab_audio(min(win, max(0.8, time.monotonic()-speech_t0+0.3)))
            db = vp_get_db()
            if d is None or db is None or not db.names:
                res = latch_to_res(latch)
            elif float(np.sqrt((d**2).mean())) <= 0.02:
                res = latch_to_res(latch)      # 短暂停顿：保持上一锁定结果
            else:
                name, score, ok, cands = db.identify(d)
                try:
                    with open(Path(tempfile.gettempdir())/'vp_scores.log','a',encoding='utf-8') as f:
                        f.write('%.3f %s %.3f %s\n' % (time.time(), name, score,
                                ','.join('%s:%.3f'%(x['name'],x['score']) for x in cands)))
                except OSError: pass
                cur = name if ok else 'unknown'
                votes.append(cur)
                if not latch['decided']:
                    pend.append(cur)
                    if len(pend) == 2 and pend[0] == pend[1]:
                        cur = pend[0]      # 连续两窗一致才首次亮名，防开头点错名；两窗都低于阈值→判定陌生人
                        latch.update(decided=True,
                                     name=None if cur == 'unknown' else cur,
                                     id='--' if cur == 'unknown' else 'SP-%03d' % (db.names.index(cur)+1),
                                     cands=cands, score=score)
                        res = latch_to_res(latch)
                    else:
                        res = {'name': '识别中…', 'id': '--', 'score': score,
                               'ok': True, 'candidates': cands}
                else:
                    top, top_n = max(((v, votes.count(v)) for v in set(votes)),
                                     key=lambda kv: kv[1])
                    if top_n >= 3:            # 已出结果后：5 窗中 3 窗一致才改判
                        if top == 'unknown':
                            latch.update(name=None, cands=cands, score=score)
                        else:
                            latch.update(name=top, id='SP-%03d' % (db.names.index(top)+1),
                                         cands=cands, score=score)
                    res = latch_to_res(latch)
        with lock:
            vp_state['data'] = res; vp_state['ts'] = time.monotonic()
        upd.set()

def enroll_from_array(name):
    """从 8 麦阵列音频录 3 段 4 秒语音注册声纹（智能等待：只在有人声时采集，最长 60s）。"""
    import numpy as np
    db = vp_get_db()
    if db is None:
        raise RuntimeError('voiceprint engine unavailable: %s' % vp_engine['err'])
    wavs = []
    deadline = time.monotonic() + 60
    while len(wavs) < 3:
        if time.monotonic() > deadline:
            raise RuntimeError('超时：60 秒内只录到 %d/3 段有效语音，请说话声音更大、更连贯' % len(wavs))
        time.sleep(1.0)                       # 每秒检查一次最近 4 秒窗口
        d = grab_audio(4.0)
        if d is None:
            raise RuntimeError('未收到阵列音频（等待板端 PS 下发 AUD3 音频包）')
        if float(np.sqrt((d**2).mean())) <= 0.02:
            continue                          # 这 4 秒太安静，继续等（允许说话人自然停顿）
        wavs.append(d.copy())
        time.sleep(1.5)                       # 段间错开，避免 3 段内容几乎相同
    db.enroll(name, wavs)
    return len(wavs)

def main():
    cfg=json.loads((Path(__file__).resolve().parents[1]/'network_config.json').read_text())
    p=argparse.ArgumentParser();p.add_argument('--port',type=int,default=cfg['udp_port'])
    p.add_argument('--http-port',type=int,default=8768);p.add_argument('--peer',default=cfg['board_ip'])
    p.add_argument('--log',type=Path,default=Path(__file__).parent/'received.jsonl');a=p.parse_args()
    state=ReceiverState(); lock=threading.Lock(); peer_name=''; last=0.0
    upd=threading.Event()  # 新包到达即唤醒推送线程，消除轮询 sleep 的人为延迟
    das_sig=''; das_t=0.0  # DAS 声源检测状态（signal + 时刻）
    sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);sock.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4*1024*1024);sock.bind(('0.0.0.0',a.port))
    a.log.parent.mkdir(parents=True,exist_ok=True)
    def receive():
        nonlocal peer_name,last,das_sig,das_t
        with a.log.open('a',encoding='utf-8') as log:
            while True:
                data,peer=sock.recvfrom(65535)
                if a.peer!='any' and peer[0] not in (a.peer,'127.0.0.1'):continue  # 板卡网口直发，或本机/队友机 JTAG 调试桥转发
                if feed_audio(data):
                    upd.set()   # AUD3 阵列音频包：入环形缓冲供声纹线程消费
                    continue
                try:m=decode(data)
                except (ValueError,TypeError,UnicodeError):continue
                if m['origin']!='board':continue
                with lock:
                    if m['kind']=='doa' and m.get('method')=='das':
                        accepted,reason=True,'accepted (das hidden)'  # DAS 方位不入显示状态，仅用 MVDR
                        das_sig=m.get('signal') or ''; das_t=time.monotonic()  # 但用 DAS 作声源检测
                    else:
                        accepted,reason=state.ingest(m)
                    if accepted:peer_name=peer[0];last=time.monotonic()
                log.write(json.dumps(dict(peer=list(peer),accepted=accepted,reason=reason,message=m),ensure_ascii=False)+'\n')
                upd.set()  # 立即唤醒所有推送连接（微秒级下发，不靠 sleep 轮询）
                if m['seq']%200==0:log.flush()  # 批量落盘，避免每包 fsync 阻塞接收
    class Handler(BaseHTTPRequestHandler):
        protocol_version='HTTP/1.1'  # SSE 需要长连接
        def _cors(self):
            # 允许 file:// 双击打开的页面跨域访问本机接口
            self.send_header('Access-Control-Allow-Origin','*')
            self.send_header('Access-Control-Allow-Methods','GET,POST,OPTIONS')
            self.send_header('Access-Control-Allow-Headers','Content-Type')
        def do_OPTIONS(self):
            self.send_response(204);self._cors()
            self.send_header('Content-Length','0');self.end_headers()
        def do_POST(self):
            path=self.path.split('?',1)[0]
            if path=='/api/vp/enroll':
                n=int(self.headers.get('Content-Length') or 0)
                try:name=str(json.loads(self.rfile.read(n) or b'{}').get('name','')).strip()
                except Exception:name=''
                if not name:
                    body=b'{"ok":false,"error":"empty name"}';code=400
                else:
                    try:enroll_from_array(name);body=json.dumps({'ok':True,'name':name,'clips':3}).encode();code=200
                    except Exception as e:body=json.dumps({'ok':False,'error':str(e)}).encode();code=500
                self.send_response(code);self._cors();self.send_header('Content-Type','application/json')
                self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
                return
            self.send_error(404);return
        def do_GET(self):
            path=self.path.split('?',1)[0]   # 允许 ?v=timestamp 破缓存，仍命中同一路由
            if path=='/api/stream':
                # 推送式：状态一变化立即下发（包到即推送，替代 30ms 轮询）
                self.send_response(200)
                self._cors()
                self.send_header('Content-Type','text/event-stream; charset=utf-8')
                self.send_header('Cache-Control','no-store')
                self.send_header('Connection','keep-alive')
                self.send_header('Transfer-Encoding','chunked')
                self.end_headers()
                last_key=None;beat=0.0;last_sent=0.0
                try:
                    while True:
                        upd.clear()          # 先清标志再取快照，避免漏掉唤醒
                        with lock:
                            d=state.latest.get('doa');c=state.latest.get('classification');sp=state.latest.get('spectrum')
                            now=time.monotonic()
                            vp=vp_state['data'] if now-vp_state['ts']<12 else None
                            snap=dict(connected=now-last<2,peer=peer_name,
                                doa=d[0] if d else None,classification=c[0] if c else None,
                                spectrum=sp[0] if sp else None,spectrum_stale=state.stale('spectrum'),
                                das_active=(now-das_t<1.0) and das_sig=='active',
                                doa_stale=state.stale('doa'),class_stale=state.stale('classification'),
                                voiceprint=vp)
                        key=((snap['doa'] or {}).get('seq'),(snap['classification'] or {}).get('seq'),
                             (snap['spectrum'] or {}).get('seq'),
                             snap['connected'],snap['doa_stale'],snap['class_stale'],snap['das_active'],
                             (vp or {}).get('name'),(vp or {}).get('ok'))
                        if (key!=last_key or now-beat>1.0) and now-last_sent>=0.005:
                            body=b'data: '+json.dumps(snap,ensure_ascii=False).encode()+b'\n\n'
                            self.wfile.write(b'%X\r\n'%len(body)+body+b'\r\n');self.wfile.flush()
                            last_key=key;beat=now;last_sent=now   # 限频 200Hz：板端 380+包/秒，全量推送会让浏览器主线程忙于解析
                        upd.wait(1.0)        # 有新包立刻醒（0 延迟），无包则每秒心跳
                except (BrokenPipeError,ConnectionResetError,OSError):return
                return
            if path=='/api/state':
                with lock:
                    d=state.latest.get('doa');c=state.latest.get('classification');sp=state.latest.get('spectrum')
                    now=time.monotonic()
                    body=json.dumps(dict(connected=now-last<2,peer=peer_name,
                        doa=d[0] if d else None,classification=c[0] if c else None,
                        spectrum=sp[0] if sp else None,spectrum_stale=state.stale('spectrum'),
                        das_active=(now-das_t<1.0) and das_sig=='active',
                        doa_stale=state.stale('doa'),class_stale=state.stale('classification'),
                        voiceprint=vp_state['data'] if now-vp_state['ts']<12 else None)).encode()
                kind='application/json'
            elif path=='/':body=PAGE.read_bytes();kind='text/html; charset=utf-8'
            elif path in ('/simple','/simple.html') and SIMPLE.exists():body=SIMPLE.read_bytes();kind='text/html; charset=utf-8'
            else:self.send_error(404);return
            self.send_response(200);self._cors();self.send_header('Content-Type',kind)
            self.send_header('Cache-Control','no-store');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        def log_message(self,*args):pass
    threading.Thread(target=receive,daemon=True).start()
    if vp_get_db() is not None:
        threading.Thread(target=vp_worker,args=(lock,upd,state),daemon=True).start()
        print(f'voiceprint: {len(vp_engine["db"].names)} speakers enrolled',flush=True)
    print(f'UDP 0.0.0.0:{a.port}, board {a.peer}; browser http://127.0.0.1:{a.http_port}',flush=True)
    class QuietServer(ThreadingHTTPServer):
        def handle_error(self,request,client_address):  # 浏览器刷新/关闭 SSE 属正常，不打印堆栈
            pass
        def server_bind(self):
            self.socket.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
            super().server_bind()
    try:QuietServer(('127.0.0.1',a.http_port),Handler).serve_forever()
    except KeyboardInterrupt:pass
    finally:sock.close()
if __name__=='__main__':main()
