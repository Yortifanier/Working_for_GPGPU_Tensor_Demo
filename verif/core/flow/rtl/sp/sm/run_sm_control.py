"""Run SM control RTL tests; distinguish normal passes and expected assertions."""
from pathlib import Path
from datetime import datetime, timezone
import argparse
import hashlib
import json
import os
import re
import resource
import shutil
import subprocess

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'setup.csh').is_file())
BUILD=ROOT/'build/sm/control_regression'
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('--suite',choices=['all','scheduler','scoreboard','control'],default='all')
p.add_argument('--jobs',type=int,default=2)
p.add_argument('--seed',type=int,default=1907)
args=p.parse_args()
BUILD.mkdir(parents=True,exist_ok=True)
resource.setrlimit(resource.RLIMIT_CORE,(0,0))
tool=Path(os.environ.get('VERILATOR') or shutil.which('verilator') or
          ROOT/'build/toolchain/verilator/usr/bin/verilator').resolve()
env=dict(os.environ)
inferred=tool.parents[1]/'share/verilator'
if inferred.is_dir():env.setdefault('VERILATOR_ROOT',str(inferred))
version=subprocess.run([str(tool),'--version'],env=env,text=True,capture_output=True,check=True).stdout.strip()
files=[ROOT/'design/core/src/common/sm_pkg.sv',ROOT/'design/core/filelist/common/sm_pkg.f']
for folder,pattern in [
 ('design/core/src/if/sp/sm','*.sv'),('design/core/src/rtl/sp/sm','*.sv'),
 ('design/core/filelist/if/sp/sm','*.f'),('design/core/filelist/rtl/sp/sm','*.f'),
 ('verif/core/src/rtl/sp/sm','*.sv'),('verif/core/filelist/rtl/sp/sm','*.f'),
 ('verif/core/flow/rtl/sp/sm','*.py')]:
 files+=list((ROOT/folder).glob(pattern))
hashes={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted(set(files))}
signature=hashlib.sha256(json.dumps(hashes,sort_keys=True).encode()).hexdigest()
common=[str(tool),'--timing','--assert','+define+SM_ASSERTIONS','--timescale','1ns/1ps',
        '-Wall','-Wno-UNUSEDSIGNAL','-Wno-UNUSEDPARAM','-Wno-SYNCASYNCNET']

def run(command,log,timeout=600,expected_assertion=None):
 with log.open('w') as out:
  result=subprocess.run(command,cwd=ROOT,env=env,stdout=out,stderr=subprocess.STDOUT,timeout=timeout)
 text=log.read_text()
 if expected_assertion:
  if result.returncode==0 or expected_assertion not in text or '_PASS' in text:
   raise SystemExit('Missing expected assertion failure: '+str(log))
 elif result.returncode:
  print(text[-8000:])
  raise SystemExit(f'Failed ({result.returncode}): {log.relative_to(ROOT)}')
 return text,result.returncode

seeds2=[args.seed,args.seed+119]
configs=[
 ('sched64','scheduler','tb_sm_warp_sched',{'WARPS':64},seeds2),
 ('sched7','scheduler','tb_sm_warp_sched',{'WARPS':7},seeds2),
 ('sched1','scheduler','tb_sm_warp_sched',{'WARPS':1},seeds2),
 ('score4','scoreboard','tb_sm_scoreboard',{'WARPS':4,'FLIGHTS':4},[args.seed]),
 ('score1','scoreboard','tb_sm_scoreboard',{'WARPS':1,'FLIGHTS':1},[args.seed]),
 ('ctrl4','control','tb_sm_instr_ctrl',{'WARPS':4,'FLIGHTS':4},seeds2),
 ('ctrl64','control','tb_sm_instr_ctrl',{'WARPS':64,'FLIGHTS':16},[args.seed]),
 ('ctrl1','control','tb_sm_instr_ctrl',{'WARPS':1,'FLIGHTS':1},[args.seed]),
]
results=[]
for name,suite,top,params,seeds in configs:
 if args.suite not in ('all',suite):continue
 folder=BUILD/name;folder.mkdir(exist_ok=True)
 filelist='verif/core/filelist/rtl/sp/sm/'+top+'.f'
 options=[f'-G{k}={v}' for k,v in params.items()]
 run(common+['--lint-only','--top-module',top]+options+['-f',filelist],folder/'lint.log')
 manifest=folder/'compiled_sources.json';binary=folder/('V'+top)
 expected={'source_signature':signature,'tool':version,'top':top,'parameters':params}
 reused=binary.exists() and manifest.exists() and json.loads(manifest.read_text())==expected
 if not reused:
  run(common+['--binary','--top-module',top,'-j',str(max(1,args.jobs)),
      '--Mdir',str(folder)]+options+['-f',filelist],folder/'compile.log')
  manifest.write_text(json.dumps(expected,indent=2)+'\n')
 for seed in seeds:
  log=folder/f'run_seed_{seed}.log'
  output,code=run([str(binary),f'+SEED={seed}'],log,timeout=180)
  match=re.search(r'SM_[A-Z_]+_PASS\b[^\n]*',output)
  if not match:raise SystemExit('No actual PASS summary: '+str(log))
  counts={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)\b',match[0])}
  if counts.get('checks',0)<=0:raise SystemExit('Zero-test result: '+str(log))
  results.append({'configuration':name,'suite':suite,'parameters':params,'seed':seed,
                  'outcome':'PASS','summary':match[0],'counts':counts,
                  'log':str(log.relative_to(ROOT)),
                  'log_sha256':hashlib.sha256(log.read_bytes()).hexdigest(),
                  'reused_compilation':reused})
  print(match[0],flush=True)
 if suite=='scheduler':
  log=folder/'negative_take.log'
  output,code=run([str(binary),'+NEGATIVE_TAKE'],log,timeout=30,
                  expected_assertion='a_take_requires_candidate')
  results.append({'configuration':name,'suite':suite,'parameters':params,
                  'outcome':'EXPECTED_ASSERTION','assertion':'a_take_requires_candidate',
                  'exit_code':code,'log':str(log.relative_to(ROOT)),
                  'log_sha256':hashlib.sha256(log.read_bytes()).hexdigest()})
  print(f'SM_EXPECTED_ASSERTION {name}: a_take_requires_candidate',flush=True)
for n,h in hashes.items():
 if hashlib.sha256((ROOT/n).read_bytes()).hexdigest()!=h:
  raise SystemExit('Source changed; rerun final evidence: '+n)
report={'kind':'SM_CONTROL_FUNCTIONAL_RTL_REGRESSION','passed':True,
        'timestamp_utc':datetime.now(timezone.utc).isoformat(),'tool':version,
        'scope':'Uniform-control IR scheduler/scoreboard/controller only. Backend BFMs are protocol models, not implemented FMA/SFU/TMA/LSU/Tensor bridges or a full SM. No ITS or SM generator testplan execution claim.',
        'requested_suite':args.suite,'source_signature':signature,'source_sha256':hashes,
        'normal_passes':sum(x['outcome']=='PASS' for x in results),
        'expected_assertion_failures':sum(x['outcome']=='EXPECTED_ASSERTION' for x in results),
        'results':results,
        'warnings_waived':{'UNUSEDSIGNAL':'Public transport fields',
                          'UNUSEDPARAM':'Shared package parameters',
                          'SYNCASYNCNET':'SVA sampling asynchronous reset',
                          'BLKSEQ':'Local procedural TB only'}}
(BUILD/f'results_{args.suite}.json').write_text(json.dumps(report,indent=2)+'\n')
print(f"Completed {report['normal_passes']} normal passes and {report['expected_assertion_failures']} expected assertion failures.")
