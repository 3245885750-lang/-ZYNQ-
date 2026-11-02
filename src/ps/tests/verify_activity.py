from pathlib import Path
import sys,os,subprocess,json
ROOT=Path(__file__).resolve().parents[1]
sys.path[:0]=[str(Path("F:/FPGA/Vitis_Workspace/radar_ps_audio_v2/capture/trials/guitar_paused_20261023/pl_handoff_002_frameid/build/python_deps")),str(ROOT/"pc")]
from unicorn import Uc,UC_ARCH_ARM,UC_MODE_ARM
from unicorn.arm_const import UC_ARM_REG_R0,UC_ARM_REG_R1,UC_ARM_REG_R2,UC_ARM_REG_SP,UC_ARM_REG_LR
from elftools.elf.elffile import ELFFile
from radar_protocol import decode
BIN=Path("F:/FPGA/2026.1/Vitis/gnu/aarch32/nt/gcc-arm-none-eabi/bin/arm-none-eabi-gcc.exe")
elfpath=ROOT/"build/activity.elf"
env=dict(os.environ,TMP=str(ROOT/"build/tmp"),TEMP=str(ROOT/"build/tmp"))
subprocess.run([str(BIN),"-mcpu=cortex-a9","-marm","-mfloat-abi=soft","-std=c99","-Wall","-Wextra","-Werror","-O2","-ffreestanding","-fno-builtin","-nostdlib","-Wl,-Ttext=0x10000","-Wl,-e,policy_message","-I"+str(ROOT/"ps"),"-I"+str(ROOT/"src"),str(ROOT/"ps/radar_wire.c"),str(ROOT/"tests/activity_harness.c"),"-lgcc","-o",str(elfpath)],env=env,check=True)
u=Uc(UC_ARCH_ARM,UC_MODE_ARM);u.mem_map(0,0x1000000)
with elfpath.open("rb") as f:
 e=ELFFile(f)
 for seg in e.iter_segments():
  if seg["p_type"]=="PT_LOAD":u.mem_write(seg["p_vaddr"],seg.data())
 syms={s.name:s["st_value"] for s in e.get_section_by_name(".symtab").iter_symbols()}
def call(name,*args):
 for reg,v in zip((UC_ARM_REG_R0,UC_ARM_REG_R1,UC_ARM_REG_R2),args):u.reg_write(reg,v)
 u.reg_write(UC_ARM_REG_SP,0xeff000);u.reg_write(UC_ARM_REG_LR,0xf00000)
 u.emu_start(syms[name],0xf00000,count=1000000)
 return u.reg_read(UC_ARM_REG_R0)
checks=[]
for p in (0,1,63,64,65,66,0xffffffff):
 assert bool(call("policy_active",p))==(p>64)
 for seq,valid,label in ((0,0,0),*[(1,1,l) for l in range(9)],(1,0,0),(1,1,9)):
  n=call("policy_message",p,seq,(valid<<8)|label);assert n
  m=decode(bytes(u.mem_read(syms["test_buffer"],n)))
  expected="background" if p<=64 else "pending" if seq==0 else "uncertain" if not valid or label>=9 else "event"
  assert m["state"]==expected,(p,seq,valid,label,m)
  if p<=64:assert m["label"]=="background" and m["confidence_ppm"] is None
  checks.append(dict(power=p,model_seq=seq,valid=valid,label=label,state=m["state"]))
result=dict(passed=True,threshold=64,comparison="strictly greater",arm_encoded_cases=len(checks),cases=checks)
(ROOT/"evidence/activity_verification.json").write_text(json.dumps(result,indent=2),encoding="utf-8")
print("PASS_SHARED_PL_THRESHOLD",len(checks),"ARM-encoded cases, boundary 64/65 and warmup/invalid states")
