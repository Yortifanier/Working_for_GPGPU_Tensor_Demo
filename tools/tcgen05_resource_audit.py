"""Audit instantiated dot arithmetic; report RTL structure, never mapped PPA."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import xml.etree.ElementTree as ET

from malu_resource_audit import audit_xml

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--engines', type=int, default=4)
    parser.add_argument('--out', type=Path, default=ROOT/'build/tcgen05/resource_audit')
    args = parser.parse_args()
    if not 1 <= args.engines <= 128:
        parser.error('engines must be in 1..128')
    folder = args.out.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    tool = os.environ.get('VERILATOR') or shutil.which('verilator')
    if not tool:
        tool = ROOT/'build/toolchain/verilator/usr/bin/verilator'
    tool = Path(tool).resolve()
    env = dict(os.environ)
    inferred = tool.parents[1]/'share/verilator'
    if inferred.is_dir():
        env.setdefault('VERILATOR_ROOT', str(inferred))
    version = subprocess.run([str(tool), '--version'], env=env, check=True,
                             capture_output=True, text=True).stdout.strip()
    results = []
    for fp64 in (0, 1):
        xml = folder/f'array_e{args.engines}_fp64_{fp64}.xml'
        command = [str(tool), '--xml-only', '--timing', '--timescale', '1ns/1ps', '-Wall',
                   '-Wno-UNUSEDSIGNAL', '-Wno-UNUSEDPARAM',
                   '--top-module', 'tcgen05_dot_array',
                   f'-GENGINES={args.engines}', f'-GENABLE_FP64=1\'b{fp64}',
                   '--xml-output', str(xml), '-f',
                   'verif/core/filelist/rtl/sp/eu/tensor/tcgen05/tb_tcgen05_dot_array.f']
        process = subprocess.run(command, env=env, cwd=ROOT, text=True,
                                 capture_output=True)
        (folder/f'elaborate_fp64_{fp64}.log').write_text(process.stdout+process.stderr)
        process.check_returncode()
        tree = ET.parse(xml)
        instances = [c for c in tree.findall('.//cells//cell')
                     if c.get('submodname', '').startswith('malu_core')]
        assert len(instances) == args.engines, len(instances)
        per_core = audit_xml(xml, bool(fp64))
        results.append({'engines': len(instances), 'enable_fp64': bool(fp64),
                        'per_core': per_core,
                        'total_numerical_multiply_paths': len(instances),
                        'total_accumulator_bytes': len(instances)*per_core['accumulator_bits']//8,
                        'xml_sha256': hashlib.sha256(xml.read_bytes()).hexdigest(),
                        'hierarchy': [i.get('hier') for i in instances]})
    paths = [p for p in (ROOT/'design/core').rglob('*.sv')
             if 'tcgen05' in p.name or 'malu' in p.name]
    report = {'kind': 'ELABORATED_RTL_RESOURCE_AUDIT', 'passed': True,
              'tool': version, 'results': results,
              'default_storage_contract': {
                  'tmem_bytes': 128*576*4,
                  'shared_result_tile_bytes_without_fp64': 256*256*4,
                  'shared_result_tile_bytes_with_fp64': 256*256*8,
                  'basis': 'Explicit RTL data capacities; not mapped macro measurements'},
              'source_sha256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                for p in sorted(paths)},
              'claim': 'Counts instantiated numerical paths and each shared accumulator. '
                       'Not DSP count, PPA, performance, or NVIDIA/Rubin physical geometry.'}
    (folder/'resources.json').write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'passed': True, 'engines': args.engines,
                      'report': str(folder/'resources.json')}, indent=2))


if __name__ == '__main__':
    main()
