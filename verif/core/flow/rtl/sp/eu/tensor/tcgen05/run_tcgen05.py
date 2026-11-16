"""Compile and execute tcgen05 functional RTL tests, retaining actual evidence."""
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

ROOT = next(p for p in Path(__file__).resolve().parents if (p / 'setup.csh').is_file())
BUILD = ROOT / 'build/tcgen05/rtl'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--jobs', type=int, default=2)
parser.add_argument('--suite', choices=['all','unit','integration','allocator','tmem',
    'array','mma','move','math','legalizer','layout','control','cluster'], default='all')
parser.add_argument('--seed', type=int, default=1907)
args = parser.parse_args()
BUILD.mkdir(parents=True, exist_ok=True)
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
tool = os.environ.get('VERILATOR') or shutil.which('verilator')
if not tool:
    candidate = ROOT / 'build/toolchain/verilator/usr/bin/verilator'
    if candidate.exists():
        tool = str(candidate)
if not tool:
    raise SystemExit('Verilator required; use python3 tools/bootstrap_verilator.py')
tool = str(Path(tool).resolve())
env = dict(os.environ)
inferred = Path(tool).parents[1] / 'share/verilator'
if inferred.is_dir():
    env.setdefault('VERILATOR_ROOT', str(inferred))
version = subprocess.run([tool, '--version'], env=env, capture_output=True, text=True, check=True).stdout.strip()

def run(command, log, timeout=600):
    with log.open('w') as stream:
        try:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=stream,
                                    stderr=subprocess.STDOUT, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise SystemExit(f'Host timeout: {log.relative_to(ROOT)}')
    if result.returncode:
        print(log.read_text()[-7000:])
        raise SystemExit(f'Failed ({result.returncode}): {log.relative_to(ROOT)}')
    return log.read_text()

files = sorted(set(
    list((ROOT / 'design/core').rglob('*.sv')) +
    list((ROOT / 'design/core').rglob('*.f')) +
    list((ROOT / 'verif/core/src/rtl/sp/eu/tensor/tcgen05').glob('*.sv')) +
    list((ROOT / 'verif/core/filelist/rtl/sp/eu/tensor/tcgen05').glob('*.f')) +
    list(Path(__file__).resolve().parent.glob('*.py'))
))
hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
signature = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
common = [tool, '--timing', '--assert', '+define+MALU_ASSERTIONS',
          '+define+TCGEN05_ASSERTIONS', '--timescale', '1ns/1ps', '-Wall',
          '-Wno-UNUSEDSIGNAL', '-Wno-UNUSEDPARAM', '-Wno-SYNCASYNCNET']
# SYNCASYNCNET: SVA samples the same asynchronous reset at a clock edge.
# BLKSEQ is locally suppressed only in procedural TBs, never in DUT RTL.
base = 'verif/core/filelist/rtl/sp/eu/tensor/tcgen05/'
configurations = [
    ('integration_default', 'integration', 'tb_tcgen05', 'tb_tcgen05.f', {}, [args.seed, args.seed + 1]),
    ('integration_small', 'integration', 'tb_tcgen05', 'tb_tcgen05.f',
     {'COLS': 64, 'LANES': 1, 'ENABLE_FP64': "1'b0"}, [args.seed + 2]),
    ('allocator_576', 'allocator', 'tb_tcgen05_allocator', 'tb_tcgen05_allocator.f',
     {'MAX_COLS': 576, 'RECORDS': 18}, [args.seed]),
    ('allocator_512', 'allocator', 'tb_tcgen05_allocator', 'tb_tcgen05_allocator.f',
     {'MAX_COLS': 512, 'RECORDS': 16}, [args.seed + 1]),
    ('allocator_records2', 'allocator', 'tb_tcgen05_allocator', 'tb_tcgen05_allocator.f',
     {'MAX_COLS': 576, 'RECORDS': 2}, [args.seed + 2]),
    ('tmem_576', 'tmem', 'tb_tcgen05_tmem', 'tb_tcgen05_tmem.f', {'COLS': 576}, [args.seed]),
    ('tmem_32', 'tmem', 'tb_tcgen05_tmem', 'tb_tcgen05_tmem.f', {'COLS': 32}, [args.seed + 1]),
    ('array_parallel','array','tb_tcgen05_dot_array','tb_tcgen05_dot_array.f',{},[args.seed,args.seed+1]),
    ('array_serial','array','tb_tcgen05_dot_array','tb_tcgen05_dot_array.f',{'ENGINES':1},[args.seed]),
    ('array_small','array','tb_tcgen05_dot_array','tb_tcgen05_dot_array.f',
     {'ENGINES':3,'LANES':1,'ENABLE_FP64':"1'b0"},[args.seed]),
    ('mma_parallel','mma','tb_tcgen05_mma','tb_tcgen05_mma.f',{},[args.seed]),
    ('mma_serial','mma','tb_tcgen05_mma','tb_tcgen05_mma.f',{'DOT_ENGINES':1},[args.seed]),
    ('mma_small','mma','tb_tcgen05_mma','tb_tcgen05_mma.f',
     {'DOT_ENGINES':3,'LANES':1,'ENABLE_FP64':"1'b0"},[args.seed]),
    ('move_complete','move','tb_tcgen05_move','tb_tcgen05_move.f',{},[args.seed,args.seed+1,2026]),
    ('move_math','math','tb_tcgen05_move_math','tb_tcgen05_move_math.f',{},[args.seed]),
    ('legalizer','legalizer','tb_tcgen05_legalize','tb_tcgen05_legalize.f',{},[args.seed]),
    ('layout','layout','tb_tcgen05_layout','tb_tcgen05_layout.f',{},[args.seed]),
    ('allocator_hub','control','tb_tcgen05_allocator_hub','tb_tcgen05_allocator_hub.f',{},[args.seed]),
    ('pair_rollback','control','tb_tcgen05_pair_rollback','tb_tcgen05_pair_rollback.f',{},[args.seed]),
    ('memory_peer_progress','control','tb_tcgen05_memory_peer_progress','tb_tcgen05_memory_peer_progress.f',{},[args.seed]),
    ('commit_fanout','control','tb_tcgen05_commit_fanout','tb_tcgen05_commit_fanout.f',{},[args.seed,args.seed+1,2026]),
    ('cluster','cluster','tb_tcgen05_cluster','tb_tcgen05_cluster.f',{},[args.seed,args.seed+1]),
]
results = []
for name, suite, top, filelist, params, seeds in configurations:
    if args.suite=='unit':
        if suite in ('integration','cluster'): continue
    elif args.suite not in ('all', suite):
        continue
    folder = BUILD / name
    folder.mkdir(exist_ok=True)
    options = [f'-G{k}={v}' for k, v in params.items()]
    run(common + ['--lint-only', '--top-module', top] + options + ['-f', base + filelist], folder / 'lint.log')
    expected = {'source_signature': signature, 'version': version, 'top': top, 'params': params}
    manifest = folder / 'compiled_sources.json'
    binary = folder / ('V' + top)
    reused = binary.exists() and manifest.exists() and json.loads(manifest.read_text()) == expected
    if not reused:
        run(common + ['--binary', '--top-module', top, '-j', str(max(1, args.jobs)),
                      '--Mdir', str(folder)] + options + ['-f', base + filelist], folder / 'compile.log')
        manifest.write_text(json.dumps(expected, indent=2) + '\n')
    for seed in seeds:
        # TMEM's existing TB defines SEED as hexadecimal; others use decimal.
        seed_arg = f'+SEED={seed:x}' if suite == 'tmem' else f'+SEED={seed}'
        logfile = folder / f'run_seed_{seed}.log'
        extra=[]
        if suite=='math':
            vector=folder/f'vectors_seed_{seed}.txt'
            run(['python3',str(Path(__file__).resolve().with_name('generate_move_vectors.py')),
                 '--out',str(vector),'--seed',str(seed),'--count','6000'],folder/f'generate_seed_{seed}.log')
            extra=['+VECTORS='+str(vector)]
        output = run([str(binary), seed_arg]+extra, logfile, timeout=180)
        match = re.search(r'TCGEN05_[A-Z_]+_PASS\b[^\n]*', output)
        if not match:
            raise SystemExit(f'Missing completed nonzero-test summary: {logfile}')
        counts = {k: int(v) for k, v in re.findall(r'(\w+)=(\d+)\b', match[0])}
        if not any(counts.get(key, 0) > 0 for key in ('checks','checked','transfers','commands','vectors','transactions','responses')):
            raise SystemExit(f'No execution count: {match[0]}')
        results.append({'configuration': name, 'suite': suite, 'seed': seed, 'passed': True,
                        'parameters': params, 'counts': counts, 'summary': match[0],
                        'log': str(logfile.relative_to(ROOT)),
                        'log_sha256': hashlib.sha256(logfile.read_bytes()).hexdigest(),
                        'reused_compilation': reused})
        print(match[0], flush=True)
for path,expected_hash in hashes.items():
    if hashlib.sha256((ROOT/path).read_bytes()).hexdigest()!=expected_hash:
        raise SystemExit('Source changed during execution; rebuild final evidence: '+path)
report = {'check_kind': 'TCGEN05_FUNCTIONAL_RTL_SIMULATION', 'passed': True,
          'timestamp_utc': datetime.now(timezone.utc).isoformat(), 'tool': version,
          'scope': 'Functional RTL unit/endpoint tests with SVA across explicit native/canonical/project cases; not a claim of Rubin physical replication, peak throughput, or execution of the 106 SM-generator testplan cases.',
          'requested_suite': args.suite, 'source_signature': signature,
          'source_sha256': hashes, 'results': results,
          'warnings_waived': {'UNUSEDSIGNAL': 'sanitized/public fields',
                              'UNUSEDPARAM': 'public constants',
                              'SYNCASYNCNET': 'SVA sampling asynchronous reset',
                              'BLKSEQ': 'local TB procedural model only'}}
(BUILD / f'results_{args.suite}.json').write_text(json.dumps(report, indent=2) + '\n')
print(f'Completed {len(results)} actual RTL simulations. Evidence: {BUILD.relative_to(ROOT)}')
