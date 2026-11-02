from pathlib import Path
import hashlib,json,shutil,zipfile,struct

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT.parent
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

# Verify the only load-image difference is the GNU linker build ID. Its hash
# changes with debug source paths, while addresses and executable bytes remain.
a=(ROOT/'audit/deployed.bin').read_bytes();b=(ROOT/'audit/rebuilt.bin').read_bytes()
marker=struct.pack('<III',4,20,3)+b'GNU\0'
assert a.count(marker)==b.count(marker)==1
offset=a.index(marker)+len(marker)
assert b.index(marker)+len(marker)==offset
assert a[:offset]==b[:offset] and a[offset+20:]==b[offset+20:]
e=json.loads((ROOT/'audit/build_equivalence.json').read_text())
e.update(identical_except_gnu_build_id=True,build_id_binary_offset=offset,build_id_bytes=20,
    original_build_id=a[offset:offset+20].hex(),rebuilt_build_id=b[offset:offset+20].hex())
(ROOT/'audit/build_equivalence.json').write_text(json.dumps(e,indent=2))

# Include the current implementation report that came with the exact archived bit.
impl=BASE/'v1030/radar_ps_audio_v2/radar_ps_audio_v2.runs/impl_1'
for name in ['radar_system_wrapper_timing_summary_routed.rpt','radar_system_wrapper_drc_routed.rpt','radar_system_wrapper_utilization_placed.rpt']:
    if (impl/name).exists():
        dest=ROOT/'audit/archived_implementation'/name;dest.parent.mkdir(exist_ok=True)
        shutil.copy2(impl/name,dest)
for name in ['configure_ps_led.tcl','ps_led_configuration.txt']:
    shutil.copy2(BASE/'radar_ps_audio_v2'/name,ROOT/'audit'/name)
project_check=(ROOT/'audit/relocated_project_check.txt').read_text()
assert 'MISSING 0' in project_check
assert 'RELOCATED_PROJECT_CHECK_PASS' in (ROOT/'audit/relocated_vivado.log').read_text(errors='replace')
assert not e['archived_repo_differences']
assert set(e['archived_bits'].values())=={sha(ROOT/'matched_payload/radar.bit')}

allowed_dirs={'audit','tools','PL_sources','PL_original','PS','matched_payload'}
allowed_files={'PL_vivado_project.zip','board_download.zip','pc_handoff.zip','先看这里_工程交接.md','PL修改核对说明.md'}
def include(p):
    rel=p.relative_to(ROOT)
    if not p.is_file():return False
    if rel.parts[0] not in allowed_dirs and str(rel) not in allowed_files:return False
    if any(part in {'__pycache__','build','tmp'} for part in rel.parts):return False
    if p.suffix.lower() in {'.pyc','.bin','.jou'}:return False
    # Preserve the successful log, not the earlier filesystem-permission failure.
    if p.name in {'vivado_archive.log'}:return False
    return True
files=sorted([p for p in ROOT.rglob('*') if include(p)])
manifest={p.relative_to(ROOT).as_posix():{'sha256':sha(p),'bytes':p.stat().st_size} for p in files}
(ROOT/'manifest.json').write_text(json.dumps(manifest,ensure_ascii=False,indent=2),encoding='utf-8')
output=BASE/'工程源码与PL修改核对_20261030.zip'
with zipfile.ZipFile(output,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
    for p in files+[ROOT/'manifest.json']:
        # The Vivado zip is already compressed.
        method=zipfile.ZIP_STORED if p.suffix=='.zip' else zipfile.ZIP_DEFLATED
        z.write(p,'radar_source_handoff/'+p.relative_to(ROOT).as_posix(),compress_type=method)
with zipfile.ZipFile(output) as z:
    assert z.testzip() is None
    for rel,item in manifest.items():
        assert hashlib.sha256(z.read('radar_source_handoff/'+rel)).hexdigest()==item['sha256'],rel
result={'archive':str(output),'bytes':output.stat().st_size,'sha256':sha(output),'files':len(files)+1,
    'ps_rebuilt':True,'ps_loaded_image_equal_except_build_id':True,
    'vivado_relocated_opened':True,'vivado_missing_files':0,'archived_bit_matches_deployed':True,
    'pl_new_synthesis_run':False,'board_programmed_this_audit':False,'zip_integrity_and_payload_hashes_checked':True}
(ROOT/'audit/delivery_verification.json').write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding='utf-8')
print(json.dumps(result,ensure_ascii=False,indent=2))
