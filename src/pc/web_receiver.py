"""PC-only UDP receiver and small browser view. No inference or generated data."""
import argparse, json, socket, threading, time
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from radar_protocol import decode, ReceiverState, describe

HTML='''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>声学雷达</title>
<style>body{font:16px system-ui;background:#f3f6fb;color:#23364f;margin:32px auto;max-width:900px}section{background:white;border-radius:12px;padding:24px;margin:18px}h1{font-size:25px}strong{font-size:32px;color:#156eb1}small{color:#68788b}table{width:100%}td{padding:6px}progress{width:100%;accent-color:#2387bc}</style>
<h1>声学雷达 · 板卡实时结果</h1><section id="connection">等待板卡 UDP 数据</section>
<section>声源方位<br><strong id="angle">—</strong><p id="method"></p></section>
<section>声音类型<br><strong id="label">等待数据</strong><p id="detail"></p><table id="scores"></table></section>
<small>方位只显示 PL 的 MVDR 精确结果；连续 2 秒没有新结果才标记为超时。有声音但把握不足显示“不确定”；低于PL门槛显示“安静”。分类使用最近2秒音频，持续更新。</small>
<script>
const ids=['clap','speech','piano','bird','dog','horn','water','zipper','keyboard'];
const names=['拍手','说话','钢琴','鸟叫','狗叫','鸣笛','流水','拉链','敲键盘'];
const status={pending:'等待音频窗口',background:'安静',uncertain:'不确定',error:'采集/识别已停止'};
function show(s){
connection.textContent=s.connected?'已接收板卡数据 · '+s.peer:'等待板卡 UDP 数据 / 数据已超时';
const d=s.doa,c=s.classification;
angle.textContent=d&&!s.doa_stale&&d.valid?(d.azimuth_mdeg/1000).toFixed(1)+'°':'—';
method.textContent=d?(d.method.toUpperCase()+' · '+(s.doa_stale?'方位数据超时':(d.signal==='quiet'?'安静 / 低于MVDR门限':(!d.valid?'无有效MVDR角度':'有效精确方位')))):'';
label.textContent=c&&!s.class_stale?(c.state==='event'?names[ids.indexOf(c.label)]:status[c.state]):'等待数据 / 识别结果超时';
detail.textContent=c?'识别窗口 #'+c.model_seq+' · 音频中断 '+c.audio_gaps+' · 跳过窗口 '+c.missed_windows:'';
scores.innerHTML=c&&!s.class_stale&&c.state!=='background'?c.scores_ppm.map((v,i)=>'<tr><td>'+names[i]+'</td><td><progress max="1000000" value="'+v+'"></progress></td><td>'+(v/10000).toFixed(1)+'%</td></tr>').join(''):'';
}
async function tick(){try{show(await(await fetch('/api/state',{cache:'no-store'})).json())}catch(e){connection.textContent='接收服务未连接'}setTimeout(tick,50)}tick();
</script></html>'''

def main():
    cfg=json.loads((Path(__file__).resolve().parents[1]/'network_config.json').read_text())
    p=argparse.ArgumentParser();p.add_argument('--port',type=int,default=cfg['udp_port'])
    p.add_argument('--http-port',type=int,default=8768);p.add_argument('--peer',default=cfg['board_ip'])
    p.add_argument('--log',type=Path,default=Path(__file__).parent/'received.jsonl');a=p.parse_args()
    state=ReceiverState(); lock=threading.Lock(); peer_name=''; last=0.0
    sock=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);sock.bind(('0.0.0.0',a.port))
    a.log.parent.mkdir(parents=True,exist_ok=True)
    def receive():
        nonlocal peer_name,last
        with a.log.open('a',encoding='utf-8') as log:
            while True:
                data,peer=sock.recvfrom(65535)
                if peer[0]!=a.peer:continue
                try:m=decode(data)
                except (ValueError,TypeError,UnicodeError):continue
                if m['origin']!='board':continue
                with lock:
                    accepted,reason=state.ingest(m)
                    if accepted:peer_name=peer[0];last=time.monotonic()
                log.write(json.dumps(dict(peer=list(peer),accepted=accepted,reason=reason,message=m),ensure_ascii=False)+'\n');log.flush()
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path=='/api/state':
                with lock:
                    d=state.latest.get('doa');c=state.latest.get('classification')
                    body=json.dumps(dict(connected=time.monotonic()-last<2,peer=peer_name,
                        doa=d[0] if d else None,classification=c[0] if c else None,
                        doa_stale=state.stale('doa'),class_stale=state.stale('classification'))).encode()
                kind='application/json'
            elif self.path=='/':body=HTML.encode('utf-8');kind='text/html; charset=utf-8'
            else:self.send_error(404);return
            self.send_response(200);self.send_header('Content-Type',kind)
            self.send_header('Cache-Control','no-store');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        def log_message(self,*args):pass
    threading.Thread(target=receive,daemon=True).start()
    print(f'UDP 0.0.0.0:{a.port}, board {a.peer}; browser http://127.0.0.1:{a.http_port}',flush=True)
    try:ThreadingHTTPServer(('127.0.0.1',a.http_port),Handler).serve_forever()
    except KeyboardInterrupt:pass
    finally:sock.close()
if __name__=='__main__':main()
