"""Compare generated nine-class C DSP/network to Python on real heldout audio."""
import os
os.environ['OPENBLAS_NUM_THREADS']='1'
os.environ['OMP_NUM_THREADS']='1'
from pathlib import Path
import sys,subprocess,ctypes as C,csv,json
import numpy as np
ROOT=Path(__file__).resolve().parents[1]
DATA=Path('F:/FPGA/Vitis_Workspace/radar_sound_classifier')
sys.path.insert(0,str(DATA))
from sound_features import load_audio,features_for_window,predict_windows
GCC=Path('F:/FPGA/2026.1/tps/mingw/10.0.0/win64.o/nt/bin/gcc.exe')
env=dict(os.environ,TMP=str(ROOT/'build/tmp'),TEMP=str(ROOT/'build/tmp'))
env['PATH']=str(GCC.parent)+os.pathsep+env.get('PATH','')
os.add_dll_directory(str(GCC.parent))
lib=ROOT/'build/nine_model.dll'
cmd=[str(GCC),'-std=c99','-O3','-Wall','-Wextra','-Werror','-shared','-static-libgcc','-DRADAR_NATIVE_TEST=1','-I',str(ROOT/'src'),str(ROOT/'src/radar_classifier.c'),str(ROOT/'src/radar_background_envelope.c'),'-o',str(lib),'-lm']
r=subprocess.run(cmd,env=env,capture_output=True,text=True)
(ROOT/'build/native_compile.log').write_text(r.stdout+r.stderr,encoding='utf8')
if r.returncode:raise RuntimeError(r.stderr)
d=C.CDLL(str(lib));P=np.ctypeslib.ndpointer(dtype=np.float32,flags='C_CONTIGUOUS')
class Result(C.Structure):
    _fields_=[('sequence',C.c_uint32),('end_sample',C.c_uint64),('label',C.c_uint32),('scores',C.c_float*9),('rms',C.c_float),('valid',C.c_uint32),('gap_count',C.c_uint32),('missed_windows',C.c_uint32)]
d.radar_classifier_window.argtypes=[P,P,P];d.radar_test_push_16k.argtypes=[P,C.c_uint];d.radar_test_features.argtypes=[P]
d.radar_classifier_step.argtypes=[C.POINTER(Result)]
model=dict(np.load(ROOT/'model/model.npz'));cfg=json.loads((ROOT/'model/model_config.json').read_text(encoding='utf8'))
labels=[x['key'] for x in cfg['classes']]
rows=list(csv.DictReader((ROOT/'model/training_manifest.csv').open(encoding='utf-8-sig')))
signals={}
for label in labels:
    row=max((x for x in rows if x['proposed_label']==label and x['official_split']=='test'),key=lambda r:float(r['duration_seconds']))
    a=load_audio(DATA/row['prepared_audio_path'])
    signals[label]=np.ascontiguousarray(np.pad(a,(0,max(0,64000-len(a))))[:64000],dtype=np.float32)
signals['silence']=np.zeros(64000,np.float32)
signals['dc']=np.full(64000,.25,np.float32)
signals['impulse']=np.where(np.arange(64000)%5300==0,.8,0).astype(np.float32)
report={'platform':'native x86_64 functional equivalence; not ARM timing','cases':[]}
for name,a in signals.items():
    d.radar_classifier_init();count=0
    for start in range(0,len(a),160):
        chunk=np.ascontiguousarray(a[start:start+160]);d.radar_test_push_16k(chunk,len(chunk))
        while d.radar_classifier_busy():
            result=Result()
            if not d.radar_classifier_step(C.byref(result)):continue
            end=result.end_sample;window=np.ascontiguousarray(a[end-32000:end]);f=np.empty(144,np.float32);d.radar_test_features(f)
            ref=features_for_window(window);rp=predict_windows(ref[None,:],model)[0];scores=np.array(result.scores)
            ferr=float(abs(f-ref).max());perr=float(abs(scores-rp).max())
            assert np.isfinite(f).all() and np.isfinite(scores).all()
            assert ferr<.03 and perr<.003,(name,end,ferr,perr)
            assert int(scores.argmax())==int(rp.argmax()),(name,end,scores,rp)
            order=np.sort(scores);t=round(cfg['rejection']['confidence']*1e6);margin=round(cfg['rejection']['margin']*1e6)
            ppm=np.floor(scores*1e6).astype(int);sorted_ppm=np.sort(ppm)
            expected=float(np.std(window))>1e-9 and sorted_ppm[-1]>=t and sorted_ppm[-1]-sorted_ppm[-2]>=margin
            assert bool(result.valid)==bool(expected),(name,end,result.valid,expected)
            assert result.gap_count==0 and result.missed_windows==0
            report['cases'].append({'signal':name,'end_sample':end,'feature_max_abs':ferr,'score_max_abs':perr,'label':labels[result.label],'valid':bool(result.valid)})
            count+=1
    assert count==21,(name,count)
    d.radar_classifier_discontinuity();z=np.zeros(31840,np.float32);d.radar_test_push_16k(z,len(z));assert not d.radar_classifier_busy()
    z=np.zeros(160,np.float32);d.radar_test_push_16k(z,len(z));got=False
    while d.radar_classifier_busy():
        out=Result()
        if d.radar_classifier_step(C.byref(out)):
            assert out.gap_count==1 and not out.valid;got=True
    assert got
    print('PASS',name,count,flush=True)
report.update(passed=True,comparisons=len(report['cases']),max_feature_error=max(x['feature_max_abs'] for x in report['cases']),max_score_error=max(x['score_max_abs'] for x in report['cases']),gap_rewarmup='passed')
(ROOT/'evidence/native_equivalence.json').write_text(json.dumps(report,indent=2),encoding='utf8')
print('NATIVE_MODEL_PASS',report['comparisons'],report['max_score_error'])
