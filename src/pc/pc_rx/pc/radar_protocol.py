"""RADAR UDP JSON v3（PL004：七类 + 安静 + 实时频谱）。Python 标准库实现。
类别顺序（PS 约定 radar7_20261101，九槽位保留、玻璃/发动机停用）：
    0 clap 1 speech 2 siren 3 bell 4 dog 5 horn 6 water (7 glass 8 engine 停用)
新增 kind="spectrum"：波束合成单声道 256 点 FFT，129 频点 dBFS。
"""
import json
import re
import time

LABELS = ('clap', 'speech', 'siren', 'bell', 'dog', 'horn', 'water', 'glass', 'engine')
NAMES = ('拍手', '说话', '警笛', '钟声', '狗叫', '汽车鸣笛', '流水', '玻璃破碎（停用）', '发动机（停用）')
CLASS_SET = 'radar7_20261101'
ENABLED_MASK = 127          # 前 7 类启用
MAX_BYTES = 1200
DOA_STALE_SECONDS = 2.0
CLASSIFICATION_STALE_SECONDS = 2.0
def integer(x, low, high):
    if type(x) is not int or not low <= x <= high: raise ValueError('integer range/type')
def counter(x):
    if not isinstance(x,str) or not re.fullmatch(r'0|[1-9][0-9]{0,19}',x) or int(x)>2**64-1:
        raise ValueError('uint64 decimal string')
def decode(data):
    if len(data)>MAX_BYTES: raise ValueError('packet exceeds 1200 bytes')
    def no_constant(x): raise ValueError('non-finite JSON value')
    def unique(pairs):
        result={}
        for k,v in pairs:
            if k in result: raise ValueError('duplicate JSON key')
            result[k]=v
        return result
    m=json.loads(data.decode('utf-8'),parse_constant=no_constant,object_pairs_hook=unique)
    if not isinstance(m,dict) or type(m.get('v')) is not int or m['v']!=3: raise ValueError('expected v3 (PL004 seven-class receiver)')
    if m.get('origin') not in ('board','replay'): raise ValueError('origin')
    if not isinstance(m.get('session'),str) or not re.fullmatch(r'[0-9a-f]{16}',m['session']): raise ValueError('session')
    integer(m.get('seq'),0,2**32-1); counter(m.get('t_us'))
    if m.get('kind')=='spectrum':
        if m.get('source')!='beamformed_pcm' or m.get('units')!='dBFS':raise ValueError('spectrum source/units')
        for key,value in [('sample_rate_hz',16000),('nfft',256),('bin_step_millihz',62500)]:
            if type(m.get(key)) is not int or m[key]!=value:raise ValueError(key)
        counter(m.get('end_sample'));integer(m.get('power'),0,2**32-1)
        if type(m.get('active')) is not bool or m['active']!=(m['power']>64):raise ValueError('spectrum activity')
        values=m.get('dbfs')
        if not isinstance(values,list) or len(values)!=129:raise ValueError('spectrum bins')
        for value in values:integer(value,-120,0)
    elif m.get('kind')=='doa':
        if m.get('method') not in ('das','mvdr') or m.get('signal') not in ('active','quiet','unknown'): raise ValueError('doa method/signal')
        integer(m.get('pl_seq'),0,2**32-1)
        if type(m.get('valid')) is not bool: raise ValueError('valid boolean')
        if m['valid']:
            integer(m.get('azimuth_mdeg'),0,359999)
            if m['signal']=='quiet': raise ValueError('quiet with valid angle')
        elif m.get('azimuth_mdeg') is not None: raise ValueError('invalid angle must be null')
    elif m.get('kind')=='classification':
        integer(m.get('model_seq'),0,2**32-1)
        if m.get('state') not in ('pending','event','background','uncertain','error'): raise ValueError('classification state')
        if m.get('enabled_mask')!=ENABLED_MASK or type(m['enabled_mask']) is not int: raise ValueError('class policy')
        if m.get('class_set')!=CLASS_SET: raise ValueError('class_set mismatch')
        integer(m.get('reject_confidence_ppm'),0,1000000); integer(m.get('reject_margin_ppm'),0,1000000)
        scores=m.get('scores_ppm')
        if not isinstance(scores,list) or len(scores)!=9: raise ValueError('nine scores')
        for score in scores: integer(score,0,1000000)
        if m['state']=='event':
            if m.get('label') not in LABELS[:7]: raise ValueError('disabled/invalid label')
            integer(m.get('confidence_ppm'),0,1000000)
            if m['confidence_ppm']!=scores[LABELS.index(m['label'])]: raise ValueError('score mismatch')
            top=sorted(scores,reverse=True)
            if m['confidence_ppm']!=top[0] or top[0]<m['reject_confidence_ppm'] or top[0]-top[1]<m['reject_margin_ppm']:
                raise ValueError('event violates rejection policy')
        else:
            if m.get('confidence_ppm') is not None or m.get('label')!=('background' if m['state']=='background' else None):
                raise ValueError('non-event label/score')
        counter(m.get('end_sample'))
        for k,v in [('sample_rate_hz',16000),('window_samples',32000)]:
            if type(m.get(k)) is not int or m[k]!=v: raise ValueError(k)
        integer(m.get('hop_samples'),1600,8000)
        if m['hop_samples'] not in (1600,8000): raise ValueError('hop_samples')
        integer(m.get('audio_gaps'),0,2**32-1); integer(m.get('missed_windows'),0,2**32-1)
    else: raise ValueError('unsupported kind')
    return m

class ReceiverState:
    def __init__(self):
        self.session=None; self.retired=set(); self.latest={}; self.stats={}
    def ingest(self,m,now=None):
        now=time.monotonic() if now is None else now
        session=(m['origin'],m['session'])
        if session in self.retired:
            # 自愈：当前活跃 session 已静默 >3s 却仍有该 session 的包进来，说明它才是真正在线的板卡，
            # 解除退役重新接管（否则自测/回放插过包后，真板卡会被永久拒收）
            active=max((v[1] for v in self.latest.values()), default=None)
            if active is None or now-active>3.0: self.retired.discard(session)
            else: return False,'retired_session'
        if session!=self.session:
            if self.session is not None: self.retired.add(self.session)
            self.session=session; self.latest={}; self.stats={}
        key=m['kind']; stats=self.stats.setdefault(key,dict(received=0,missing=0,duplicate=0,out_of_order=0))
        old=self.latest.get(key)
        if old:
            delta=(m['seq']-old[0]['seq'])&0xffffffff
            if delta==0: stats['duplicate']+=1;return False,'duplicate'
            # 仅用 seq 判定乱序（不掺 t_us）：历史上板端 t_us 曾周期性回退，seq 判序经实测最稳
            if delta>=0x80000000:
                back=(old[0]['seq']-m['seq'])&0xffffffff
                if back<=1000:  # 小幅回退=网络乱序，丢弃
                    stats['out_of_order']+=1;return False,'out_of_order'
                # 大幅回退=板卡重启发号重新计数，重置缓存后接受
                self.latest={}; self.stats={}; stats=self.stats.setdefault(key,dict(received=0,missing=0,duplicate=0,out_of_order=0))
                old=None
            if old: stats['missing']+=delta-1
        stats['received']+=1; self.latest[key]=(m,now)
        return True,'accepted'
    def stale(self,kind,now=None):
        now=time.monotonic() if now is None else now
        return kind not in self.latest or now-self.latest[kind][1]>2.0

def describe(m):
    prefix='[历史回放] ' if m['origin']=='replay' else '[板上结果] '
    if m['kind']=='doa':
        value=f"{m['azimuth_mdeg']/1000:.1f}°" if m['valid'] else '无有效方位'
        return f"{prefix}方位 seq={m['seq']} {m['method'].upper()} {value} signal={m['signal']}"
    if m['kind']=='spectrum':return f"{prefix}频谱 seq={m['seq']} 129 bins 0..8000Hz dBFS power={m['power']}"
    state=m['state']
    value=NAMES[LABELS.index(m['label'])] if state=='event' else dict(background='安静',uncertain='不确定',pending='等待窗口',error='采集/识别错误')[state]
    score=f" {m['confidence_ppm']/10000:.1f}%" if state=='event' else ''
    return f"{prefix}类型 seq={m['seq']} {value}{score}"
