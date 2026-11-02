"""Exercise the packaged HTTP/UDP bridge on loopback ephemeral ports only."""
from pathlib import Path
import sys,socket,subprocess,urllib.request,json,time
ROOT=Path(__file__).resolve().parents[1]
def port(kind):
    with socket.socket(socket.AF_INET,kind) as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
udp=port(socket.SOCK_DGRAM);http=port(socket.SOCK_STREAM)
p=subprocess.Popen([sys.executable,'-X','utf8','-B',str(ROOT/'pc/web_receiver.py'),'--port',str(udp),'--http-port',str(http),'--peer','127.0.0.1','--log',str(ROOT/'evidence/web_loopback.jsonl')],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,encoding='utf8',creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
try:
    assert 'UDP ' in p.stdout.readline()
    base=f'http://127.0.0.1:{http}'
    for _ in range(50):
        try:
            with urllib.request.urlopen(base,timeout=1) as r:page=r.read().decode('utf8')
            break
        except OSError:time.sleep(.05)
    else:raise AssertionError('HTTP did not start')
    assert "'water','zipper','keyboard'" in page and '猫叫' not in page and '吉他' not in page
    fixtures=[json.loads(s) for s in (ROOT/'examples_v3/protocol_fixtures.jsonl').read_text(encoding='utf8').splitlines()]
    states=[]
    with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as s:
        for fixture in fixtures:
            fixture.update(origin='board')
            s.sendto(json.dumps(fixture).encode(),('127.0.0.1',udp))
            for _ in range(50):
                with urllib.request.urlopen(base+'/api/state',timeout=1) as r:state=json.load(r)
                c=state.get('classification')
                if c and c['seq']==fixture['seq']:break
                time.sleep(.02)
            else:raise AssertionError('UDP result did not reach HTTP state')
            assert state['connected'] and not state['class_stale'] and c['label']==fixture['label'] and c['state']==fixture['state']
            assert len(c['scores_ppm'])==9
            states.append(c['label'] or c['state'])
    report={'passed':True,'destination':'127.0.0.1 ephemeral ports only','synthetic_protocol_test':True,'states':states,'http_udp_bridge_verified':True,'remote_pc_verified':False}
    (ROOT/'evidence/web_verification.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf8')
    print('WEB_RECEIVER_PASS',states)
finally:
    p.terminate();p.communicate(timeout=5)
