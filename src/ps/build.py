"""Build the handed-over standalone ARM firmware. Never connects to a board."""
from pathlib import Path
import argparse, hashlib, json, os, shutil, subprocess

ROOT=Path(__file__).resolve().parent
def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gcc-bin',type=Path,help='Vitis gnu/aarch32/nt/gcc-arm-none-eabi/bin')
    args=parser.parse_args()
    candidates=[]
    if args.gcc_bin: candidates.append(args.gcc_bin)
    if os.environ.get('XILINX_VITIS'):
        candidates.append(Path(os.environ['XILINX_VITIS'])/'gnu/aarch32/nt/gcc-arm-none-eabi/bin')
    found=shutil.which('arm-none-eabi-gcc.exe')
    if found: candidates.append(Path(found).parent)
    candidates += [Path(d+'/FPGA/2026.1/Vitis/gnu/aarch32/nt/gcc-arm-none-eabi/bin') for d in ['F:','D:','C:']]
    tool=next((p.resolve() for p in candidates if (p/'arm-none-eabi-gcc.exe').is_file()),None)
    if tool is None: parser.error('Pass --gcc-bin with the installed Vitis ARM toolchain bin directory')
    out=ROOT/'build'; out.mkdir(exist_ok=True); (out/'tmp').mkdir(exist_ok=True)
    env=dict(os.environ,TMP=str(out/'tmp'),TEMP=str(out/'tmp'))
    env['PATH']=str(tool)+os.pathsep+env.get('PATH','')
    def run(command,log):
        command=list(map(str,command))
        result=subprocess.run(command,env=env,capture_output=True,text=True,errors='replace')
        (out/(log+'.log')).write_text(result.stdout+result.stderr,encoding='utf-8')
        if result.returncode: raise RuntimeError(result.stdout+result.stderr)
        return result.stdout
    bsp=ROOT/'deps/audio_bsp'; net=ROOT/'deps/network_bsp'
    flags=['-DSDT','-mcpu=cortex-a9','-mfpu=vfpv3','-mfloat-abi=hard',f'-specs={bsp}/Xilinx.spec',
        '-isystem',bsp/'include','-isystem',net/'include','-I',ROOT/'src','-I',ROOT/'ps','-I',ROOT/'deps/phy',
        '-Wall','-Wextra','-Werror','-std=c99','-O3','-g3','-U__clang__','-DRADAR_ENABLE_CLASSIFIER=1','-fno-math-errno']
    sources=[ROOT/'src'/n for n in ['radar_background_envelope.c','radar_classifier.c','radar_pcm_stream.c','radar_stream_ring.c']]
    sources += [ROOT/'ps'/n for n in ['radar_network.c','radar_wire.c','radar_udp_lwip.c','radar_board_physpeed.c']]
    objects=[]; commands=[]
    for p in sources:
        obj=out/(p.stem+'.o'); objects.append(obj)
        command=[tool/'arm-none-eabi-gcc.exe',*flags,'-c',p,'-o',obj]
        print('COMPILE',p.name,flush=True);run(command,p.stem)
        commands.append({'file':str(p),'directory':str(ROOT),'arguments':list(map(str,command))})
    elf=out/'radar_audio_classifier_ethernet.elf'
    run([tool/'arm-none-eabi-gcc.exe',*flags,*objects,f'-Wl,-T,{ROOT}/lscript.ld',f'-Wl,-Map,{out}/radar.map',
        '-L',bsp/'lib','-L',net/'lib','-Wl,--start-group','-lxilstandalone','-lxiltimer','-llwip220','-lxil','-lgcc','-lc','-lm','-Wl,--end-group','-o',elf],'link')
    symbols=run([tool/'arm-none-eabi-nm.exe','-S','-n',elf],'symbols')
    addresses={}
    for line in symbols.splitlines():
        fields=line.split()
        if len(fields)==4 and fields[3] in ['g_network_boot_nonce','g_network_header','g_stream_header','g_classifier_header']:
            addresses[fields[3]]='0x'+fields[0]
    if len(addresses)!=4: raise RuntimeError('Required diagnostic symbols missing')
    size=run([tool/'arm-none-eabi-size.exe',elf],'size')
    (out/'mailbox_addresses.json').write_text(json.dumps(addresses,indent=2))
    (out/'compile_commands.json').write_text(json.dumps(commands,indent=2))
    (out/'build_result.json').write_text(json.dumps({'elf':str(elf),'sha256':hashlib.sha256(elf.read_bytes()).hexdigest(),
        'symbols':addresses,'size':size,'board_programmed':False,'toolchain':str(tool)},indent=2))
    print('ARM_BUILD_PASS\n'+size,json.dumps(addresses),flush=True)
if __name__=='__main__': main()
