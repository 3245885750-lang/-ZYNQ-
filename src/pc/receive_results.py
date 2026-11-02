import argparse
import datetime
import json
from pathlib import Path
import socket
import time
from radar_protocol import decode,ReceiverState,describe

def main():
    p=argparse.ArgumentParser(description='接收板卡 UDP JSON v3 方位/分类结果')
    cfg=json.loads((Path(__file__).resolve().parents[1]/'network_config.json').read_text(encoding='utf-8'))
    p.add_argument('--bind',default='0.0.0.0');p.add_argument('--port',type=int,default=cfg['udp_port'])
    p.add_argument('--peer',help='可选：只接收此板卡 IPv4')
    p.add_argument('--log',type=Path,default=Path(__file__).resolve().parent/'received.jsonl')
    p.add_argument('--seconds',type=float,default=0,help='0=持续接收')
    args=p.parse_args();state=ReceiverState();stale={}
    args.log.parent.mkdir(parents=True,exist_ok=True)
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as sock,args.log.open('a',encoding='utf-8') as log:
        sock.bind((args.bind,args.port));sock.settimeout(.1);start=time.monotonic()
        print(f'READY UDP {args.bind}:{args.port}；等待数据，未自动生成结果。',flush=True)
        try:
            while not args.seconds or time.monotonic()-start<args.seconds:
                try:
                    data,peer=sock.recvfrom(65535)
                    if args.peer and peer[0]!=args.peer: continue
                    try: m=decode(data)
                    except (ValueError,UnicodeError,TypeError) as e:
                        print(f'REJECT {peer}: {e}',flush=True);continue
                    accepted,reason=state.ingest(m)
                    log.write(json.dumps(dict(received_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                        peer=list(peer),accepted=accepted,reason=reason,message=m),ensure_ascii=False)+'\n');log.flush()
                    if accepted:
                        print(describe(m),flush=True)
                        # PC GUI integration point: update the corresponding kind
                        # only; schedule widget updates on its UI thread.
                except socket.timeout: pass
                for kind in state.latest:
                    current=state.stale(kind)
                    if current and not stale.get((state.session,kind),False):
                        print(f'STALE {kind}：结果超时，界面应清除实时标记。',flush=True)
                    stale[state.session,kind]=current
        except KeyboardInterrupt: pass
    print(json.dumps(state.stats,ensure_ascii=False),flush=True)
if __name__=='__main__':main()
