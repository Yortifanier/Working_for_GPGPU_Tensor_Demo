#!/usr/bin/env python3
"""Exercise P0 validator error detection on temporary metadata copies only."""
from __future__ import annotations

import argparse
import csv
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('_testplan_validator', ROOT / 'check_testplan.py')
validator = importlib.util.module_from_spec(spec); spec.loader.exec_module(validator)
FILES = ['testcases.json', 'campaigns.json', 'config_profiles.json', 'planned_runs.json', 'run_matrix.csv', 'SM_INSTR_GEN_TESTPLAN.md']


def edit_json(directory, name, change):
    path = directory / name; data = json.loads(path.read_text()); change(data)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + '\n')


def csv_seed(directory):
    path = directory / 'run_matrix.csv'
    with path.open(newline='') as stream:
        reader = csv.DictReader(stream); fields = reader.fieldnames; rows = list(reader)
    rows[0]['seed'] = str(int(rows[0]['seed']) + 1)
    with path.open('w', newline='') as stream:
        writer = csv.DictWriter(stream, fieldnames=fields); writer.writeheader(); writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan-dir', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args(); plan = args.plan_dir.resolve()
    mutations = [
        ('claim_dynamic_pass', 'NOT_RUN', lambda d: edit_json(d, 'testcases.json', lambda x: x['cases'][0].update(current_status='PASS'))),
        ('too_few_steps', 'steps', lambda d: edit_json(d, 'testcases.json', lambda x: x['cases'][0].update(steps=['one', 'two']))),
        ('too_few_checkpoints', 'checkpoints', lambda d: edit_json(d, 'testcases.json', lambda x: x['cases'][0].update(checkpoints=['one']))),
        ('duplicate_source_sig', 'duplicate source SIG', lambda d: edit_json(d, 'testcases.json', lambda x: x['cases'][1].update(source_testpoint_id=x['cases'][0]['source_testpoint_id']))),
        ('fixed_seed_drift', 'fixed seed must use the 0-based source index', lambda d: edit_json(d, 'testcases.json', lambda x: x['cases'][0].update(fixed_seed=x['cases'][0]['fixed_seed']+4096))),
        ('enabled_dynamic_profile', 'dynamic profile must remain disabled', lambda d: edit_json(d, 'config_profiles.json', lambda x: next(p for p in x['profiles'] if p['id']=='TP-GEN-BASE').update(enabled_for_execution=True))),
        ('unit_claims_dut_coverage', 'DUT coverage requires P3/P4', lambda d: edit_json(d, 'testcases.json', lambda x: x['cases'][0].update(coverage_ids=['CV-ISA-003']))),
        ('suite_reverse_link', 'reverse suite.case_ids link missing', lambda d: edit_json(d, 'campaigns.json', lambda x: x['suites'][0]['case_ids'].pop(0))),
        ('planned_seed_drift', 'planned expansion mismatch: seed', lambda d: edit_json(d, 'planned_runs.json', lambda x: x['runs'][0].update(seed=x['runs'][0]['seed']+1))),
        ('planned_phase_drift', 'planned expansion mismatch: phase', lambda d: edit_json(d, 'planned_runs.json', lambda x: x['runs'][0].update(phase='P4_SOC' if x['runs'][0]['phase']!='P4_SOC' else 'P1_GENERATOR_UNIT'))),
        ('input_hash_drift', 'plan_inputs SHA256 mismatch', lambda d: edit_json(d, 'planned_runs.json', lambda x: x['plan_inputs'].update({'testcases.json':'0'*64}))),
        ('csv_value_drift', 'JSON/CSV values or row order differ', csv_seed),
        ('source_hash_drift', 'source SHA256 mismatch', lambda d: edit_json(d, 'testcases.json', lambda x: x['source_files']['vplan_testpoints'].update(sha256='0'*64))),
        ('unknown_markdown_case', 'unknown=', lambda d: (d/'SM_INSTR_GEN_TESTPLAN.md').write_text((d/'SM_INSTR_GEN_TESTPLAN.md').read_text()+'\nTC-FAKE-999\n')),
    ]
    results = []
    with tempfile.TemporaryDirectory(prefix='testplan-validator-', dir='/tmp') as temp:
        directory = Path(temp)

        def restore():
            for name in FILES:
                shutil.copyfile(plan / name, directory / name)

        restore(); errors, *_ = validator.run(directory)
        if errors:
            raise RuntimeError('Baseline must pass before validator selftest: ' + '; '.join(errors[:5]))
        for name, diagnostic, mutate in mutations:
            restore(); mutate(directory); errors, *_ = validator.run(directory)
            rejected = any(diagnostic in error for error in errors)
            if not rejected:
                raise RuntimeError(f'{name}: expected diagnostic {diagnostic!r}, got {errors[:5]}')
            results.append({'mutation': name, 'rejected': True, 'expected_diagnostic': diagnostic})
    report = {'passed': True, 'check_kind': 'STATIC_VALIDATOR_SELFTEST',
              'scope': 'Synthetic corruptions of temporary metadata copies only. No planned generator, model, adapter or DUT test executed.',
              'dynamic_execution': 'NOT_RUN', 'dynamic_testcases_executed': 0,
              'checker_sha256': validator.sha(ROOT/'check_testplan.py'),
              'selftest_sha256': validator.sha(Path(__file__)),
              'baseline_input_sha256': {name: validator.sha(plan/name) for name in FILES},
              'baseline_passed': True, 'mutations_rejected': len(results), 'cases': results}
    output = args.output or plan / 'reports/checker_selftest.json'; output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(f'Static validator selftest PASS; {len(results)} metadata corruptions rejected; dynamic cases NOT_RUN; {output}')


if __name__ == '__main__':
    main()
