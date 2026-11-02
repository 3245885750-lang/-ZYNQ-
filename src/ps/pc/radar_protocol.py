"""RADAR UDP JSON v3. Python standard library only."""
import json
import re
import time

LABELS = ('clap', 'speech', 'piano', 'bird', 'dog', 'horn', 'water', 'zipper', 'keyboard')
NAMES = ('拍手', '说话', '钢琴', '鸟叫', '狗叫', '鸣笛', '流水', '拉链', '敲键盘')
MAX_BYTES = 1200
# Result cadence is determined by PL MVDR computation, not PS poll rate.
# 2 s also covers the older validated bitstream's ~1.3 s MVDR cadence.
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
    if not isinstance(m,dict) or type(m.get('v')) is not int or m['v']!=3: raise ValueError('expected v3; install the nine-class receiver')
    if m.get('origin') not in ('board','replay'): raise ValueError('origin')
    if not isinstance(m.get('session'),str) or not re.fullmatch(r'[0-9a-f]{16}',m['session']): raise ValueError('session')
    integer(m.get('seq'),0,2**32-1); counter(m.get('t_us'))
    if m.get('kind')=='doa':
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
        if m.get('enabled_mask')!=511 or type(m['enabled_mask']) is not int: raise ValueError('class policy')
        if m.get('class_set')!='radar9_20261028': raise ValueError('class_set mismatch')
        integer(m.get('reject_confidence_ppm'),0,1000000); integer(m.get('reject_margin_ppm'),0,1000000)
        scores=m.get('scores_ppm')
        if not isinstance(scores,list) or len(scores)!=9: raise ValueError('nine scores')
        for score in scores: integer(score,0,1000000)
        if m['state']=='event':
            if m.get('label') not in LABELS: raise ValueError('disabled/invalid label')
            integer(m.get('confidence_ppm'),0,1000000)
            if m['confidence_ppm']!=scores[LABELS.index(m['label'])]: raise ValueError('score mismatch')
            top=sorted(scores,reverse=True)
            if m['confidence_ppm']!=top[0] or top[0]<m['reject_confidence_ppm'] or top[0]-top[1]<m['reject_margin_ppm']: raise ValueError('event violates rejection policy')
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
        if session in self.retired: return False,'retired_session'
        if session!=self.session:
            if self.session is not None: self.retired.add(self.session)
            self.session=session; self.latest={}; self.stats={}
        key=m['kind']; stats=self.stats.setdefault(key,dict(received=0,missing=0,duplicate=0,out_of_order=0))
        old=self.latest.get(key)
        if old:
            delta=(m['seq']-old[0]['seq'])&0xffffffff
            if delta==0: stats['duplicate']+=1;return False,'duplicate'
            if delta>=0x80000000 or int(m['t_us'])<int(old[0]['t_us']):
                stats['out_of_order']+=1;return False,'out_of_order'
            stats['missing']+=delta-1
        stats['received']+=1; self.latest[key]=(m,now)
        return True,'accepted'
    def stale(self,kind,now=None):
        now=time.monotonic() if now is None else now
        timeout = DOA_STALE_SECONDS if kind == 'doa' else CLASSIFICATION_STALE_SECONDS
        return kind not in self.latest or now-self.latest[kind][1] > timeout

def describe(m):
    prefix='[历史回放] ' if m['origin']=='replay' else '[板上结果] '
    if m['kind']=='doa':
        value=f"{m['azimuth_mdeg']/1000:.1f}°" if m['valid'] else '无有效方位'
        return f"{prefix}方位 seq={m['seq']} {m['method'].upper()} {value} signal={m['signal']}"
    state=m['state']
    value=NAMES[LABELS.index(m['label'])] if state=='event' else dict(background='安静',uncertain='不确定',pending='等待窗口',error='采集/识别错误')[state]
    score=f" {m['confidence_ppm']/10000:.1f}%" if state=='event' else ''
    return f"{prefix}类型 seq={m['seq']} {value}{score}"
