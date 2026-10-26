"""Run the three documented MALU verification rounds and retain real logs."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import resource
import shutil
import subprocess
import sys
from datetime import datetime
from zoneinfo import ZoneInfo

ROOT=Path(__file__).resolve().parents[1]
BUILD=ROOT/'build/malu'
parser=argparse.ArgumentParser()
parser.add_argument('--round',choices=['1','2','3','all'],default='all')
parser.add_argument('--lint-only',action='store_true')
parser.add_argument('--jobs',type=int,default=2)
args=parser.parse_args()
BUILD.mkdir(parents=True,exist_ok=True)
tool=os.environ.get('VERILATOR') or shutil.which('verilator')
if not tool:
    candidate=ROOT/'build/toolchain/verilator/usr/bin/verilator'
    if candidate.exists():tool=str(candidate)
if not tool:raise SystemExit('Verilator is required: run python3 tools/bootstrap_verilator.py')
tool=str(Path(tool).resolve());environment=dict(os.environ)
inferred=Path(tool).parents[1]/'share/verilator'
if inferred.is_dir():environment.setdefault('VERILATOR_ROOT',str(inferred))
resource.setrlimit(resource.RLIMIT_CORE,(0,0))

def run(command,log):
    log.parent.mkdir(parents=True,exist_ok=True)
    with log.open('w') as out:
        p=subprocess.run(command,cwd=ROOT,env=environment,stdout=out,stderr=subprocess.STDOUT)
    if p.returncode:
        print(log.read_text()[-7000:])
        raise SystemExit(f'Command failed ({p.returncode}); see {log.relative_to(ROOT)}')
    return log.read_text()

version=subprocess.run([tool,'--version'],env=environment,capture_output=True,text=True,check=True).stdout.strip()
files=sorted(list((ROOT/'design/core').rglob('*.sv'))+list((ROOT/'verif/core').rglob('*.sv'))+list((ROOT/'design/core').rglob('*.f'))+list((ROOT/'verif/core').rglob('*.f')))
hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
signature=hashlib.sha256(json.dumps(hashes,sort_keys=True).encode()).hexdigest()
# Only unused public package constants and already-validated structure fields
# are waived. Width/latch/blocking-data-path warnings remain fatal. Assertions
# are enabled in every functional run and are never disabled to pass a test.
common=[tool,'--timing','--assert','+define+MALU_ASSERTIONS','--timescale','1ns/1ps',
        '-Wall','-Wno-UNUSEDSIGNAL','-Wno-UNUSEDPARAM']

lint_log=BUILD/'lint/latest.log'
run(common+['--lint-only','--top-module','malu_core','-f','design/core/filelist/rtl/sp/eu/tensor/malu/malu.f'],lint_log)
if args.lint_only:
    print('MALU lint passed: '+version);sys.exit(0)

def executable(lanes,fp64,report_dir):
    directory=BUILD/f'obj_l{lanes}_f{int(fp64)}'
    binary=directory/'Vtb_malu'
    manifest=directory/'source_fingerprint.json'
    expected={'signature':signature,'version':version,'lanes':lanes,'fp64':fp64}
    reused=binary.exists() and manifest.exists() and json.loads(manifest.read_text())==expected
    if not reused:
        directory.mkdir(parents=True,exist_ok=True)
        command=common+['--binary','--top-module','tb_malu','-j',str(max(1,args.jobs)),
            f'-GLANES={lanes}',f"-GENABLE_FP64=1'b{int(fp64)}",'--Mdir',str(directory),
            '-f','verif/core/filelist/rtl/sp/eu/tensor/malu/tb_malu.f']
        run(command,report_dir/f'compile_l{lanes}_f{int(fp64)}.log')
        manifest.write_text(json.dumps(expected,indent=2)+'\n')
    return binary,reused

def config(number,suite,seed,count,lanes=4,fp64=True):
    report_dir=BUILD/f'round{number}'
    vector=report_dir/f'vectors_l{lanes}_f{int(fp64)}.txt'
    command=[sys.executable,'tools/generate_malu_vectors.py','--suite',suite,'--seed',str(seed),
             '--count',str(count),'--out',str(vector)]
    if not fp64:command.append('--no-fp64')
    run(command,report_dir/f'generate_l{lanes}_f{int(fp64)}.log')
    expected=json.loads(vector.with_suffix('.json').read_text())['cases']
    binary,reused=executable(lanes,fp64,report_dir)
    output=run([str(binary),'+VECTORS='+str(vector),'+SEED='+str(seed)],report_dir/f'run_l{lanes}_f{int(fp64)}.log')
    match=re.search(r'MALU_PASS numerical=(\d+) protocol=(\d+) lanes=(\d+) fp64=(\d+) cycles=(\d+)',output)
    if not match:raise SystemExit('No completed test summary; zero-test or incomplete run is not accepted')
    numerical,protocol,actual_lanes,actual_fp64,cycles=map(int,match.groups())
    assert numerical==expected and numerical>0 and protocol>=10
    assert actual_lanes==lanes and actual_fp64==int(fp64)
    result={'suite':suite,'seed':seed,'numerical':numerical,'protocol':protocol,'cycles':cycles,
            'lanes':lanes,'fp64':fp64,'reused_compilation':reused,'passed':True}
    print(f'Round {number}: {numerical} numerical + {protocol} protocol cases passed (lanes={lanes},fp64={int(fp64)})')
    return result

def inventory():
    out=BUILD/'round3'
    result={}
    for fp64 in [True,False]:
        xml=out/f'resources_fp64_{int(fp64)}.xml'
        run(common+['--xml-only','--top-module','malu_core',f"-GENABLE_FP64=1'b{int(fp64)}",
             '--xml-output',str(xml),'-f','design/core/filelist/rtl/sp/eu/tensor/malu/malu.f'],out/f'resources_fp64_{int(fp64)}.log')
        from malu_resource_audit import audit_xml
        result[str(fp64)]=audit_xml(xml,fp64)
        core=(ROOT/'design/core/src/rtl/sp/eu/tensor/malu/malu_core.sv').read_text()
        no_comments=re.sub(r'/\*[\s\S]*?\*/|//[^\n]*','',core)
        assert not re.search(r'\b(real|shortreal)\b|\$bitsto',no_comments)
    (out/'resource_inventory.json').write_text(json.dumps(result,indent=2)+'\n')
    return result

rounds=[1,2,3] if args.round=='all' else [int(args.round)]
for number in rounds:
    results=[]
    if number==1:results.append(config(1,'smoke',1,0))
    if number==2:results.append(config(2,'random',1907,400))
    if number==3:
        results.append(config(3,'exhaustive',2026,200))
        results.append(config(3,'smoke',29,0,lanes=1,fp64=False))
    report={'round':number,'passed':True,'timestamp':datetime.now(ZoneInfo('Asia/Shanghai')).isoformat(),
            'tool':version,'source_signature':signature,'source_sha256':hashes,'configurations':results,
            'lint_waivers':['UNUSEDSIGNAL: unused sanitized fields','UNUSEDPARAM: public package constants']}
    if number==3:report['resource_inventory']=inventory()
    (BUILD/f'round{number}').mkdir(exist_ok=True)
    (BUILD/f'round{number}/results.json').write_text(json.dumps(report,indent=2)+'\n')
print('Requested MALU checks completed.')
