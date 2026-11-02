"""Verify payload hashes and portable Tcl control flow, without board access."""
from pathlib import Path
import subprocess,json,os,hashlib,zipfile,base64
ROOT=Path(__file__).resolve().parents[1]
PACKAGE=ROOT/'板卡下载包_九类及不确定'
manifest=json.loads((PACKAGE/'manifest.json').read_text(encoding='utf8'))
for name,sha in manifest['files'].items():assert hashlib.sha256((PACKAGE/name).read_bytes()).hexdigest()==sha
result=subprocess.run(['powershell.exe','-NoProfile','-ExecutionPolicy','Bypass','-File',str(PACKAGE/'download.ps1'),'-VerifyOnly'],capture_output=True,text=True)
assert result.returncode==0 and 'VERIFY_ONLY' in result.stdout,(result.returncode,result.stdout,result.stderr)
runtime=(ROOT/'evidence/board_download.log').read_text(encoding='utf8')
snap={}
for line in runtime.splitlines():
    words=line.split()
    if words and words[0].startswith('g_'):snap[words[0]]=[int(x) for x in words[1:]]
cases={
    'success':{},
    'audio_stalled':{'g_stream_header_later':{10:snap['g_stream_header'][10]}},
    'wrong_class_count':{'g_classifier_header_later':{49:8}},
    'network_failed':{'g_network_header_later':{3:1}},
    'audio_gap':{'g_classifier_header_later':{12:1}},
}
testdir=ROOT/'build/portable_package_tests';testdir.mkdir(exist_ok=True)
env=dict(os.environ,TMP=str(ROOT/'build/tmp'),TEMP=str(ROOT/'build/tmp'))
reports=[]
for case,patch in cases.items():
    fixture={k:v.copy() for k,v in snap.items()}
    for key,changes in patch.items():
        for index,value in changes.items():fixture[key][index]=value
    # All hardware commands are overridden BEFORE loading the package Tcl.
    lines=['set nonce_hi 0x12345678','set nonce_lo 0x87654321',
           'foreach name {connect disconnect targets rst stop configparams con after} {proc $name args {return}}',
           'proc fpga args {if {![file exists [lindex $args 1]]} {error "bit missing"}}',
           'proc dow args {if {![file exists [lindex $args 0]]} {error "ELF missing"}}',
           'proc mwr args {if {[lindex $args 0] != 0x001668a4 || [llength [lindex $args 1]] != 2} {error "nonce address/length"}}',
           'rename source real_source',
           'proc source args {if {[file tail [lindex $args end]] eq "ps7_init.tcl"} {proc ps7_init {} {}; proc ps7_post_config {} {}; return}; real_source {*}$args}',
           'array set snapshots {}','array set calls {}']
    for address,key in [('0x01a958ec','g_network_header'),('0x00273980','g_stream_header'),('0x00274280','g_classifier_header')]:
        lines.extend([f'set snapshots({address},1) '+'{'+ ' '.join(map(str,fixture[key]))+'}',
                      f'set snapshots({address},2) '+'{'+ ' '.join(map(str,fixture[key+'_later']))+'}',
                      f'set calls({address}) 0'])
    lines.append('proc mrd args {global snapshots calls; set address [lindex $args 1]; set number [incr calls($address)]; return $snapshots($address,$number)}')
    encoded=base64.b64encode((PACKAGE/'download.tcl').as_posix().encode('utf8')).decode('ascii')
    lines.append('real_source -encoding utf-8 [encoding convertfrom utf-8 [binary decode base64 {'+encoded+'}]]')
    path=testdir/(case+'.tcl');path.write_text('\n'.join(lines)+'\n',encoding='utf8')
    r=subprocess.run(['F:/FPGA/2026.1/Vitis/bin/xsdb.bat',str(path)],env=env,capture_output=True,text=True,encoding='utf8',errors='replace',timeout=30)
    output=r.stdout+r.stderr;(testdir/(case+'.log')).write_text(output,encoding='utf8')
    if case=='success':assert r.returncode==0 and 'DOWNLOAD_OK' in output,(case,output)
    else:assert 'DOWNLOAD_FAILED' in output and 'DOWNLOAD_OK' not in output,(case,output)
    # Some AMD batch launchers return zero even after Tcl exit 1. The PS
    # launcher deliberately also requires the DOWNLOAD_OK marker.
    reports.append({'case':case,'native_exit_code':r.returncode,'success_marker': 'DOWNLOAD_OK' in output,'passed':True})
with zipfile.ZipFile(ROOT/'板卡下载包_九类及不确定.zip') as z:
    assert z.testzip() is None
    assert all(name in z.namelist() for name in ['download.cmd','download.ps1','download.tcl','manifest.json',*manifest['files']])
report={'passed':True,'payload_hashes_match_deployed_pair':True,'powershell_verify_only':'passed','tcl_control_flow_with_mocked_hardware':reports,'recipient_computer_tested':False,'no_board_access_in_these_tests':True}
(ROOT/'evidence/board_package_verification.json').write_text(json.dumps(report,indent=2),encoding='utf8')
print(json.dumps(report,indent=2))
