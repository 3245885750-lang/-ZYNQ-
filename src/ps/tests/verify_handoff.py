"""Run ARM C encoder, strict Python decoding and actual local UDP receive tests."""
from pathlib import Path
import sys,json,subprocess,socket,os
ROOT=Path(__file__).resolve().parents[1]
DEPS=Path(r'F:\FPGA\Vitis_Workspace\radar_ps_audio_v2\capture\trials\guitar_paused_20261023\pl_handoff_002_frameid\build\python_deps')
sys.path[:0]=[str(DEPS),str(ROOT/'pc')]
from unicorn import Uc,UC_ARCH_ARM,UC_MODE_ARM
from unicorn.arm_const import UC_ARM_REG_R0,UC_ARM_REG_R1,UC_ARM_REG_R2,UC_ARM_REG_SP,UC_ARM_REG_LR
from elftools.elf.elffile import ELFFile
from radar_protocol import decode,ReceiverState
cfg=json.loads((ROOT/'network_config.json').read_text(encoding='utf-8'))
assert cfg['udp_port']==9000 and cfg['configured_on_hardware'] is False
assert f'#define RADAR_PC_PORT {cfg["udp_port"]}u' in (ROOT/'ps/radar_network_config.h').read_text(encoding='utf-8')
GCC=r'F:\FPGA\2026.1\Vitis\gnu\aarch32\nt\gcc-arm-none-eabi\bin\arm-none-eabi-gcc.exe'
elfpath=ROOT/'build/wire.elf'
(ROOT/'build/tmp').mkdir(parents=True,exist_ok=True)
compile_env=dict(os.environ,TMP=str(ROOT/'build/tmp'),TEMP=str(ROOT/'build/tmp'))
subprocess.run([GCC,'-mcpu=cortex-a9','-marm','-mfloat-abi=soft','-std=c99','-Wall','-Wextra','-Werror',
    '-O2','-ffreestanding','-fno-builtin','-nostdlib','-Wl,-Ttext=0x10000','-Wl,-e,test_doa',
    '-I'+str(ROOT/'ps'),'-I'+str(ROOT/'src'),str(ROOT/'ps/radar_wire.c'),str(ROOT/'tests/wire_harness.c'),'-lgcc','-o',str(elfpath)],check=True,env=compile_env)
uc=Uc(UC_ARCH_ARM,UC_MODE_ARM);uc.mem_map(0,0x1000000)
with elfpath.open('rb') as f:
    elf=ELFFile(f)
    for seg in elf.iter_segments():
        if seg['p_type']=='PT_LOAD':uc.mem_write(seg['p_vaddr'],seg.data())
    syms={s.name:s['st_value'] for s in elf.get_section_by_name('.symtab').iter_symbols()}
def call(name,*args):
    for reg,val in zip([UC_ARM_REG_R0,UC_ARM_REG_R1,UC_ARM_REG_R2],args):uc.reg_write(reg,val&0xffffffff)
    uc.reg_write(UC_ARM_REG_SP,0xeff000);uc.reg_write(UC_ARM_REG_LR,0xf00000)
    uc.emu_start(syms[name],0xf00000,count=1000000)
    n=uc.reg_read(UC_ARM_REG_R0)
    return bytes(uc.mem_read(syms['test_buffer'],n)) if n else b''
messages=[]
for angle,expected in [(-180000,180000),(-90000,270000),(0,0),(180000,180000),(179999,179999)]:
    b=call('test_doa',angle,0,1201);m=decode(b)
    assert m['azimuth_mdeg']==expected and m['t_us']=='9007199254740993'
    messages.append(b)
assert not call('test_doa',180001,0,1201)
assert not call('test_doa',0,2,1201)
assert decode(call('test_doa',0,1,1201))['azimuth_mdeg'] is None
for label in range(9):
    b=call('test_class',label,1,1201);m=decode(b);messages.append(b)
    assert m['state']=='event'
    assert m['end_sample']==str(2**64-1)
for state in [0,2,3,4]: decode(call('test_class',0,state,1201))
assert not call('test_class',9,1,1201)
# Background does not consume label; it must still encode background.
assert decode(call('test_class',9,2,1201))['label']=='background'
assert not call('test_class',10,2,1201) # harness injects score > 1000000
assert not call('test_class',0,5,1201)
assert not call('test_session')
reference=call('test_class',1,1,1201)
for cap in [0,1,10,len(reference)]:assert not call('test_class',1,1,cap)
assert call('test_class',1,1,len(reference)+1)==reference
base=decode(messages[0]);state=ReceiverState()
base['seq']=0xfffffffe;assert state.ingest(base.copy(),0)[0]
base['seq']=0xffffffff;assert state.ingest(base.copy(),.01)[0]
base['seq']=0;assert state.ingest(base.copy(),.02)[0]
assert not state.ingest(base.copy(),.03)[0]
base['seq']=2;assert state.ingest(base.copy(),.04)[0]
assert state.stats['doa']['missing']==1
base['seq']=1;assert not state.ingest(base.copy(),.05)[0]
assert not state.stale('doa',.4) and state.stale('doa',2.2)
new=dict(base,session='fedcba9876543210',seq=1)
assert state.ingest(new,.5)[0] and not state.ingest(base,.51)[0]
for bad in [b'{"v":1}',b'{}',b'[]',b'{"v":2,"v":2}',b'NaN',b'\xff',b'x'*1201]:
    try:decode(bad)
    except (ValueError,UnicodeError):pass
    else:raise AssertionError('bad packet accepted')
# Live and classification streams are independent; only doa can go stale.
s=ReceiverState();d=decode(messages[0]);c=decode(reference)
assert s.ingest(d,0)[0] and s.ingest(c,.01)[0]
assert not s.stale('doa',.4) and not s.stale('classification',.4)
assert s.stale('doa',2.2) and s.stale('classification',2.2)
policy=json.loads((ROOT/'model/model_config.json').read_text(encoding='utf8'))['rejection']
t=int(round(policy['confidence']*1000000));margin=int(round(policy['margin']*1000000))
for top,runner,expected in [(t-1,0,'uncertain'),(t,0,'event'),(900000,900000-margin+1,'uncertain'),(900000,900000-margin,'event'),(500000,500000,'uncertain')]:
    assert decode(call('test_rejection',top,runner,8))['state']==expected
fixtures=[]
for label in range(9):
    m=decode(call('test_class',label,1,1201));m.update(seq=label,origin='replay');fixtures.append(m)
for i,state_id in enumerate((2,3,0,4),9):
    m=decode(call('test_class',0,state_id,1201));m.update(seq=i,origin='replay');fixtures.append(m)
fixture=ROOT/'examples_v3/protocol_fixtures.jsonl'
fixture.write_text(''.join(json.dumps(m,separators=(',',':'))+'\n' for m in fixtures),encoding='utf8')
(ROOT/'examples_v3/README.txt').write_text('Synthetic ARM encoder protocol fixtures; not board observations or measured model predictions.\n',encoding='utf8')
# Wrong class order, legacy version and malformed score fields must fail loudly.
for edit in [dict(v=2),dict(class_set='old'),dict(scores_ppm=[0]*8),dict(label='cat'),dict(label='guitar'),dict(confidence_ppm=0)]:
    bad=dict(decode(reference),**edit)
    try:decode(json.dumps(bad).encode())
    except ValueError:pass
    else:raise AssertionError(edit)
# Real receiver subprocess, loopback only, ephemeral port (never send to colleague).
with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as probe:
    probe.bind(('127.0.0.1',0));port=probe.getsockname()[1]
log=ROOT/'evidence/loopback_received.jsonl'
log.write_text('',encoding='utf-8')
p=subprocess.Popen([sys.executable,'-X','utf8','-B',str(ROOT/'pc/receive_results.py'),
    '--bind','127.0.0.1','--port',str(port),'--seconds','2.5','--log',str(log)],
    stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,encoding='utf-8')
assert 'READY' in p.stdout.readline()
with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as sock:
    for b in [messages[0],reference,reference,b'not json']:sock.sendto(b,('127.0.0.1',port))
out=p.communicate(timeout=6)[0];assert p.returncode==0
rows=[json.loads(x) for x in log.read_text(encoding='utf-8').splitlines()]
assert len(rows)==3 and sum(x['accepted'] for x in rows)==2
assert 'REJECT' in out and 'STALE doa' in out
(ROOT/'evidence/loopback_console.txt').write_text(out,encoding='utf-8')
# Exercise the supplied replay sender through a real receiver, loopback only.
replay_log=ROOT/'evidence/replay_received.jsonl'
replay_log.write_text('',encoding='utf-8')
p=subprocess.Popen([sys.executable,'-X','utf8','-B',str(ROOT/'pc/receive_results.py'),
    '--bind','127.0.0.1','--port',str(port),'--seconds','1.5','--log',str(replay_log)],
    stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,encoding='utf-8')
assert 'READY' in p.stdout.readline()
subprocess.run([sys.executable,'-X','utf8','-B',str(ROOT/'pc/replay_saved.py'),
    '--ip','127.0.0.1','--port',str(port),'--interval','.01'],check=True,stdout=subprocess.PIPE)
replay_out=p.communicate(timeout=6)[0];assert p.returncode==0
replay_rows=[json.loads(x) for x in replay_log.read_text(encoding='utf-8').splitlines()]
assert len(replay_rows)==13 and all(x['accepted'] and x['message']['origin']=='replay' for x in replay_rows)
(ROOT/'evidence/replay_console.txt').write_text(replay_out,encoding='utf-8')
result={'passed':True,'arm_encoder':'real Cortex-A9 code under Unicorn',
    'checks':['angle normalization','null invalid angle','nine labels, cat/guitar absent, confidence/margin rejection','background/uncertain/error',
    '64bit decimal losslessness','buffer bounds','bad input','UDP sequence wrap/gap/duplicate/reorder',
    'session replacement','stale per kind','strict decoder','real UDP loopback receiver',
    'network config/header port 9000 consistency','13 synthetic ARM-encoded schema fixtures via replay sender'],
    'loopback_accepted':2,'loopback_duplicate':1,'loopback_malformed_rejected':1,
    'replay_accepted':13,'configured_destination_port':cfg['udp_port'],
    'test_destination':'127.0.0.1 ephemeral port only',
    'max_observed_payload_bytes':max(map(len,messages)),'board_ethernet_tested':False}
(ROOT/'evidence/verification.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
print(json.dumps(result,ensure_ascii=False,indent=2))
for name,b in [('doa_schema_fixture.json',messages[1]),('classification_schema_fixture.json',reference)]:
    # These are SYNTHETIC protocol test fixtures, NOT board observations.
    (ROOT/'examples_v3'/name).write_bytes(b+b'\n')
