from pathlib import Path
import hashlib, json, shutil, zipfile, difflib

ROOT = Path(__file__).resolve().parents[1]
BASE = ROOT.parent
PL = BASE/'radar_ps_audio_v2'
PS = BASE/'radar_nine_class_20261028'
ARCHIVES = Path('C:/Users/zengy/Documents/WeChat Files/wxid_k1ter1tfgwpj22/FileStorage/File/2026-10')
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p, s):
    p.parent.mkdir(parents=True,exist_ok=True)
    p.write_text(s,encoding='utf-8')
def copy(a,b):
    b.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(a,b)
def tree(a,b): shutil.copytree(a,b,dirs_exist_ok=True)

manifest=json.loads((PL/'source_manifest.json').read_text(encoding='utf-8'))
rows=[]; diffs=[]
cache=PL/'vivado_final/radar_ps_audio_v2.gen/sources_1/bd/radar_system/ipshared/51c6/src'
with zipfile.ZipFile(ARCHIVES/'radar_pl.xpr.zip') as z:
    for rel, entry in manifest.items():
        current=PL/rel
        name=current.relative_to(PL/'ip_repo/radar_pl_audio/src')
        original=PL/'original'/name
        archive_bytes=z.read(entry['archive_entry'])
        assert hashlib.sha256(archive_bytes).hexdigest()==sha(original)==entry['original_sha256'], name
        r={'file':str(name),'original_sha256':sha(original),'current_sha256':sha(current),'changed':sha(original)!=sha(current)}
        if (cache/name).is_file():
            r['generated_copy_sha256']=sha(cache/name)
            r['generated_matches_current']=sha(cache/name)==sha(current)
            assert r['generated_matches_current'],name
        rows.append(r)
        copy(original,ROOT/'PL_original'/name)
        if r['changed']:
            diffs.extend(difflib.unified_diff(original.read_text(encoding='utf-8-sig',errors='replace').splitlines(True),current.read_text(encoding='utf-8-sig',errors='replace').splitlines(True),fromfile='original/'+str(name),tofile='integrated/'+str(name)))

xci_rel=Path('fft_512/fft_512.xci')
old=json.loads((PL/'original'/xci_rel).read_text())['ip_inst']
new=json.loads((PL/'ip_repo/radar_pl_audio/src'/xci_rel).read_text())['ip_inst']
def values(x):
    return {k:[v.get('value') for v in vs] for k,vs in x['parameters']['component_parameters'].items()}
oldp,newp=values(old),values(new)
fft_changes={k:{'old':oldp.get(k),'new':newp.get(k)} for k in sorted(oldp.keys()|newp.keys()) if oldp.get(k)!=newp.get(k)}
write(ROOT/'audit/PL_source_changes.diff',''.join(diffs))
later=[]
with zipfile.ZipFile(ARCHIVES/'radar_pl_002.xpr.zip') as z:
    for name in ['mvdr_axi_top.v','mvdr_sweep.v','bf_audio_out.v','doa_uart.v','radar_pl_top_bd.v']:
        candidates=[n for n in z.namelist() if n.endswith('/'+name) and '/imports/' in n]
        if not candidates: candidates=[n for n in z.namelist() if n.endswith('/'+name)]
        data=z.read(candidates[0]); original=PL/'original'/name
        later.append({'file':name,'archive_entry':candidates[0],'same_as_initial_original':hashlib.sha256(data).hexdigest()==sha(original)})
        copy(original,ROOT/'PL_original'/name)
        if data!=original.read_bytes():
            write(ROOT/'audit'/('later_002_'+name+'.diff'),''.join(difflib.unified_diff(original.read_text(encoding='utf-8-sig').splitlines(True),data.decode('utf-8-sig').splitlines(True),fromfile='initial/'+name,tofile='002/'+name)))

tree(PL/'ip_repo',ROOT/'PL_sources/ip_repo')
tree(PL/'integration',ROOT/'PL_sources/integration')
copy(PL/'radar_timing.xdc',ROOT/'PL_sources/radar_timing.xdc')
copy(PL/'vivado_final/radar_ps_audio_v2.srcs/sources_1/bd/radar_system/radar_system.bd',ROOT/'PL_sources/radar_system.bd')
for name in ['src','ps','pc','tests']:
    shutil.copytree(PS/name,ROOT/'PS'/name,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
for name in ['model.npz','model_config.json','classes.json','metrics.json','selection_frozen.json','training_manifest.csv','rejection_policy.json']:
    copy(PS/'model'/name,ROOT/'PS/model'/name)
for name in ['network_config.json','release_status.json','接入已有网页.md','PC接收步骤.md']:
    copy(PS/name,ROOT/'PS'/name)
copy(PS/'build/lscript.ld',ROOT/'PS/lscript.ld')
copy(BASE/'radar_ps_pl_udp/src/radar_phy_hooks.h',ROOT/'PS/deps/phy/radar_phy_hooks.h')
bsp=PL/'capture/ws_c2230ce26ee3/audio_capture_platform/export/audio_capture_platform/sw/standalone_a9'
net=BASE/'radar_ps_pl_udp/platform/sw/standalone_a9'
for source,dest in [(bsp,ROOT/'PS/deps/audio_bsp'),(net,ROOT/'PS/deps/network_bsp')]:
    for name in ['include','lib']: tree(source/name,dest/name)
    if (source/'Xilinx.spec').exists(): copy(source/'Xilinx.spec',dest/'Xilinx.spec')
copy(PS/'build/radar_audio_classifier_ethernet.elf',ROOT/'matched_payload/radar.elf')
copy(PL/'radar_audio_bringup.bit',ROOT/'matched_payload/radar.bit')
copy(PL/'radar_audio_bringup.xsa',ROOT/'matched_payload/radar.xsa')
copy(PS/'板卡下载包_九类及不确定.zip',ROOT/'board_download.zip')
copy(PS/'PC交接包_九类及不确定.zip',ROOT/'pc_handoff.zip')
for name in ['arm_build.json','board_runtime.json','board_package_verification.json']:
    copy(PS/'evidence'/name,ROOT/'audit/historical_runtime'/name)

bit=sha(ROOT/'matched_payload/radar.bit')
reuse=[]
for rel in ['ethernet_classification_20261025','ethernet_low_latency_20261027','radar_nine_class_20261028']:
    p=BASE/rel/'evidence/arm_build.json'
    if p.exists():
        data=json.loads(p.read_text(encoding='utf-8'))
        reuse.append({'release':rel,'recorded_bit_sha256':data.get('bit_sha256'),'same_as_current':data.get('bit_sha256')==bit})
report={'baseline_archive':str(ARCHIVES/'radar_pl.xpr.zip'),'source_file_count':len(rows),'sources':rows,'fft_component_values_changes':fft_changes,'fft_component_reference_same':old['component_reference']==new['component_reference'],'fft_generation_directory':{'original':old['gen_directory'],'current':new['gen_directory']},'later_002_comparison':later,'bit_reuse':reuse,'payload_hashes':{p.name:sha(p) for p in (ROOT/'matched_payload').iterdir()},'board_programmed_this_audit':False,'angle_jump_root_cause_confirmed':False}
write(ROOT/'audit/source_audit.json',json.dumps(report,ensure_ascii=False,indent=2))
print(json.dumps({'modified_files':[r['file'] for r in rows if r['changed']],'fft_component_values_changes':fft_changes,'cached_matches':sum('generated_matches_current' in r for r in rows),'payload_hashes':report['payload_hashes']},ensure_ascii=False,indent=2))
