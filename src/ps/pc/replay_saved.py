"""Explicitly labelled protocol fixture replay; never labelled board or live data."""
import argparse,json,secrets,socket,time
from pathlib import Path
from radar_protocol import decode
def main():
    cfg=json.loads((Path(__file__).resolve().parents[1]/'network_config.json').read_text(encoding='utf-8'))
    p=argparse.ArgumentParser();p.add_argument('--ip',default='127.0.0.1');p.add_argument('--port',type=int,default=cfg['udp_port'])
    p.add_argument('--file',type=Path,default=Path(__file__).resolve().parents[1]/'examples_v3/protocol_fixtures.jsonl')
    p.add_argument('--interval',type=float,default=.5);a=p.parse_args()
    session=secrets.token_hex(8)
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as sock:
        for seq,line in enumerate(a.file.read_text(encoding='utf-8').splitlines()):
            m=json.loads(line);m.update(origin='replay',session=session,seq=seq)
            data=json.dumps(m,separators=(',',':')).encode();decode(data)
            sock.sendto(data,(a.ip,a.port));print(f'REPLAY {seq} -> {a.ip}:{a.port}',flush=True);time.sleep(a.interval)
if __name__=='__main__':main()
