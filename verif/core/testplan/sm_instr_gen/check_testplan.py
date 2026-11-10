#!/usr/bin/env python3
"""Check execution-plan metadata only; never run a generator, model or DUT."""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path
import re

from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[3]
PHASES = {'P0_PLAN_STATIC', 'P1_GENERATOR_UNIT', 'P2_REFERENCE_PROGRAM', 'P3_SM_RTL', 'P4_SOC'}
SUITES = ['SMOKE', 'DIRECTED', 'NEGATIVE', 'RANDOM', 'STRESS', 'REPLAY']
TIMEOUTS = {'GEN_BOUNDED', 'REFERENCE_BOUNDED', 'SM_PROGRESS', 'SOC_PROGRESS'}
PROFILES = {
    'TP-P0-STATIC': 'P0_PLAN_STATIC',
    'TP-GEN-BASE': 'P1_GENERATOR_UNIT', 'TP-GEN-NEGATIVE': 'P1_GENERATOR_UNIT',
    'TP-REF-BASE': 'P2_REFERENCE_PROGRAM',
    'TP-SM-BASE': 'P3_SM_RTL', 'TP-SM-STRESS': 'P3_SM_RTL',
    'TP-SOC-BASE': 'P4_SOC', 'TP-SOC-FAULT': 'P4_SOC',
}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(plan_dir):
    errors, counts, inputs, source_hashes = [], {}, {}, {}

    def check(condition, message):
        if not condition:
            errors.append(message)

    def load(name, schema_name):
        try:
            path = plan_dir / name
            data = json.loads(path.read_text())
            inputs[name] = sha(path)
            schema = json.loads((ROOT / 'schemas' / schema_name).read_text())
            validator = Draft202012Validator(schema, format_checker=FormatChecker())
            failures = sorted(validator.iter_errors(data), key=lambda e: str(list(e.absolute_path)))
            for failure in failures:
                errors.append(f'{name}:{"/".join(map(str, failure.absolute_path))}: {failure.message}')
            return None if failures else data
        except (OSError, ValueError) as exc:
            errors.append(f'{name}: {exc}')
            return None

    def repo_path(value):
        path = (REPO / value).resolve()
        if Path(value).is_absolute() or not path.is_relative_to(REPO):
            raise ValueError('source path must stay relative to repository: ' + value)
        return path

    cases_doc = load('testcases.json', 'testcases.schema.json')
    campaigns = load('campaigns.json', 'campaigns.schema.json')
    profiles_doc = load('config_profiles.json', 'config_profiles.schema.json')
    runs_doc = load('planned_runs.json', 'planned_runs.schema.json')
    if any(value is None for value in [cases_doc, campaigns, profiles_doc, runs_doc]):
        return errors, counts, inputs, source_hashes

    sources = cases_doc['source_files']
    source_data = {}
    for other in [campaigns, profiles_doc, runs_doc]:
        check(other['source_files'] == sources, 'top-level source_files differ')
        for field in ['version', 'date']:
            check(other[field] == cases_doc[field], 'top-level ' + field + ' differs')
    for name, record in sources.items():
        try:
            path = repo_path(record['path']); actual = sha(path)
            source_hashes[record['path']] = actual
            check(actual == record['sha256'], 'source SHA256 mismatch: ' + record['path'])
            source_data[name] = json.loads(path.read_text()) if path.suffix == '.json' else path.read_text()
        except (OSError, ValueError) as exc:
            errors.append('source file: ' + str(exc))
    if not all(key in source_data for key in ['vplan_testpoints', 'vplan_features', 'vplan_document', 'sm_architecture']):
        return errors, counts, inputs, source_hashes
    original = source_data['vplan_testpoints']['testpoints']
    source_tests = {t['id']: t for t in original}
    source_indices = {t['id']: index for index, t in enumerate(original)}
    features = source_data['vplan_features']['features']
    coverage = {cv['id']: (f['id'], cv) for f in features for cv in f['coverage_points']}
    check(len(original) == len(source_tests) == 106, 'source testpoint count must be 106 unique entries')
    check(len(coverage) == 75, 'source coverage count must be 75')
    check(all(t.get('execution') == 'NOT_RUN' and t.get('status') == 'PLANNED' for t in original), 'source testpoints must remain PLANNED / NOT_RUN')
    for name, digest in runs_doc['plan_inputs'].items():
        check(inputs.get(name) == digest, 'planned_runs plan_inputs SHA256 mismatch: ' + name)

    profiles = {}
    for profile in profiles_doc['profiles']:
        pid = profile['id']
        check(pid not in profiles, 'duplicate profile: ' + pid); profiles[pid] = profile
        check(profile['phase'] == PROFILES.get(pid), pid + ': profile phase mismatch')
        if pid == 'TP-P0-STATIC':
            check(profile['phase'] == 'P0_PLAN_STATIC', pid + ': static profile phase mismatch')
            check(profile['kind'] == 'PLAN_STATIC' and profile['enabled_for_execution'], pid + ': only the P0 static metadata checker may be enabled')
        else:
            check(profile['kind'] == 'PLANNED_DYNAMIC', pid + ': dynamic kind mismatch')
            check(not profile['enabled_for_execution'], pid + ': dynamic profile must remain disabled')
    check(set(profiles) == set(PROFILES), 'expected exactly eight declared profiles')

    case_map, source_seen, seeds, used_coverage = {}, set(), set(), set()
    for case in cases_doc['cases']:
        cid, sid = case['id'], case['source_testpoint_id']
        check(cid not in case_map, 'duplicate case ID: ' + cid); case_map[cid] = case
        check(sid not in source_seen, 'duplicate source SIG: ' + sid); source_seen.add(sid)
        check(cid == sid.replace('SIG-', 'TC-', 1), cid + ': TC/source SIG identity mismatch')
        source = source_tests.get(sid)
        check(source is not None, cid + ': unknown source SIG ' + sid)
        if source:
            check(case['source_title'] == source['title'], cid + ': source_title mismatch')
            for field in ['phase', 'feature_ids', 'coverage_ids']:
                check(case[field] == source[field], cid + ': source ' + field + ' mismatch')
            check(case['fixed_seed'] == 0x534D0000 + source_indices[sid], cid + ': fixed seed must use the 0-based source index')
        check(case['config_profile'] in profiles, cid + ': unknown config profile')
        if case['config_profile'] in profiles:
            check(profiles[case['config_profile']]['phase'] == case['phase'], cid + ': profile/case phase mismatch')
            check(not profiles[case['config_profile']]['enabled_for_execution'], cid + ': case uses enabled dynamic profile')
        check(case['fixed_seed'] not in seeds, cid + ': duplicate fixed seed'); seeds.add(case['fixed_seed'])
        expected_timeout = {'P1_GENERATOR_UNIT': 'GEN_BOUNDED', 'P2_REFERENCE_PROGRAM': 'REFERENCE_BOUNDED', 'P3_SM_RTL': 'SM_PROGRESS', 'P4_SOC': 'SOC_PROGRESS'}
        check(case['timeout_policy'] == expected_timeout.get(case['phase']), cid + ': timeout/phase mismatch')
        for cv in case['coverage_ids']:
            used_coverage.add(cv); check(cv in coverage, cid + ': unknown coverage ID ' + cv)
            if cv in coverage:
                owner, point = coverage[cv]
                check(owner in case['feature_ids'], cid + ': coverage owner missing from feature_ids')
                if point['scope'] == 'DUT_SCENARIO':
                    check(case['phase'] in {'P3_SM_RTL', 'P4_SOC'}, cid + ': DUT coverage requires P3/P4')
    check(len(case_map) == 106, 'expected 106 unique cases')
    check(source_seen == set(source_tests), 'TC/source SIG set mismatch')
    check(used_coverage == set(coverage), 'testplan must retain all 75 source coverage IDs')

    suite_map = {}
    for suite in campaigns['suites']:
        sid = suite['id']; check(sid not in suite_map, 'duplicate suite: ' + sid); suite_map[sid] = suite
        check(suite['seed_offset'] == SUITES.index(sid) * 0x100000, sid + ': seed_offset must follow fixed suiteIndex')
        check(len(suite['case_ids']) == len(set(suite['case_ids'])), sid + ': duplicate case membership')
        for cid in suite['case_ids']:
            check(cid in case_map, sid + ': unknown case ' + cid)
            if cid in case_map:
                check(sid in case_map[cid]['suites'], sid + ': reverse case.suites link missing for ' + cid)
    check(set(suite_map) == set(SUITES), 'expected the six unique suite IDs')
    for cid, case in case_map.items():
        for sid in case['suites']:
            check(cid in suite_map.get(sid, {}).get('case_ids', []), cid + ': reverse suite.case_ids link missing for ' + sid)
    check(set(campaigns['timeout_policies']) == TIMEOUTS, 'expected the four timeout policies')

    expected_runs = {}
    for sid in SUITES:
        suite = suite_map.get(sid)
        if suite is None:
            continue
        for cid in suite['case_ids']:
            if cid not in case_map:
                continue
            case = case_map[cid]
            for repeat in range(suite['repetitions']):
                key = (sid, cid, repeat)
                expected_runs[key] = {
                    'run_id': f'PLAN-{sid}-{cid}-R{repeat:02d}', 'suite_id': sid,
                    'case_id': cid, 'source_testpoint_id': case['source_testpoint_id'],
                    'phase': case['phase'], 'config_profile': case['config_profile'],
                    'repeat_index': repeat, 'case_fixed_seed': case['fixed_seed'],
                    'seed': case['fixed_seed'] + SUITES.index(sid) * 0x100000 + repeat * 0x10000,
                    'timeout_policy': case['timeout_policy'], 'current_status': 'NOT_RUN',
                    'current_gate': 'BLOCKED_MISSING_IMPLEMENTATION',
                }
    check(len({run['seed'] for run in expected_runs.values()}) == len(expected_runs), 'planned seed formula produces collisions; adjust suite repetition budgets')
    check(all(0 <= run['seed'] <= 0xFFFFFFFF for run in expected_runs.values()), 'planned seed formula exceeds unsigned 32-bit range')
    seen_runs, run_ids, run_seeds = set(), set(), set()
    for run in runs_doc['runs']:
        rid = run['run_id']; key = (run['suite_id'], run['case_id'], run['repeat_index'])
        check(key not in seen_runs, rid + ': duplicate planned-run tuple'); seen_runs.add(key)
        check(rid not in run_ids, 'duplicate run_id: ' + rid); run_ids.add(rid)
        check(run['seed'] not in run_seeds, rid + ': duplicate planned seed'); run_seeds.add(run['seed'])
        expected = expected_runs.get(key)
        check(expected is not None, rid + ': run absent from declared suite expansion')
        if expected:
            for field, value in expected.items():
                check(run[field] == value, rid + ': planned expansion mismatch: ' + field)
    check(seen_runs == set(expected_runs), 'planned_runs does not exactly expand suite case lists and repetitions')
    csv_path = plan_dir / 'run_matrix.csv'
    try:
        columns = ['run_id', 'suite_id', 'case_id', 'source_testpoint_id', 'phase', 'config_profile', 'repeat_index', 'case_fixed_seed', 'seed', 'timeout_policy', 'current_status', 'current_gate']
        with csv_path.open(newline='') as stream:
            reader = csv.DictReader(stream); csv_columns = reader.fieldnames; rows = list(reader)
        inputs[csv_path.name] = sha(csv_path)
        check(csv_columns == columns, 'run_matrix.csv columns/order mismatch')
        check(len(rows) == len(runs_doc['runs']), 'run_matrix.csv row count mismatch')
        for index, (row, run) in enumerate(zip(rows, runs_doc['runs'])):
            check(row == {key: str(run[key]) for key in columns}, f'run_matrix.csv row {index+1}: JSON/CSV values or row order differ')
    except (OSError, ValueError) as exc:
        errors.append('run_matrix.csv: ' + str(exc))
    counts.update(cases=len(case_map), source_testpoints=len(source_tests), coverage_points=len(used_coverage), profiles=len(profiles), suites=len(suite_map), planned_runs=len(runs_doc['runs']), unique_planned_seeds=len(run_seeds), planned_runs_by_suite={sid: sum(run['suite_id'] == sid for run in runs_doc['runs']) for sid in SUITES})
    markdown = plan_dir / 'SM_INSTR_GEN_TESTPLAN.md'
    try:
        text = markdown.read_text(); inputs[markdown.name] = sha(markdown)
        for label, prefix, expected in [('cases', 'TC', set(case_map)), ('source SIGs', 'SIG', set(source_tests)), ('coverage', 'CV', set(coverage))]:
            found = set(re.findall(r'(?<![A-Za-z0-9_-])' + prefix + r'-[A-Z0-9_-]+-[0-9]{3}(?![A-Za-z0-9_-])', text))
            check(found == expected, f'Markdown {label}: missing={sorted(expected-found)}, unknown={sorted(found-expected)}')
        check('NOT_RUN' in text and 'BLOCKED_MISSING_IMPLEMENTATION' in text, 'Markdown must state NOT_RUN and implementation gate')
    except OSError as exc:
        errors.append('Markdown: ' + str(exc))
    return errors, counts, inputs, source_hashes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan-dir', type=Path, default=ROOT)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    errors, counts, inputs, sources = run(args.plan_dir.resolve())
    report = {'check_kind': 'TESTPLAN_STATIC_CHECK', 'result': 'FAIL' if errors else 'PASS', 'passed': not errors,
              'scope': 'Execution-plan schema, source identity, links, suite membership and planned seed expansion only; no runner or dynamic tests.',
              'dynamic_execution': 'NOT_RUN', 'dynamic_testcases_executed': 0, 'counts': counts,
              'input_sha256': inputs, 'source_file_sha256': sources, 'checker_sha256': sha(Path(__file__)),
              'schema_sha256': {p.name: sha(p) for p in sorted((ROOT / 'schemas').glob('*.json'))}, 'errors': errors}
    output = args.output or args.plan_dir / 'reports/testplan_static_check.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(f"Testplan static check {report['result']}; dynamic tests NOT_RUN; errors={len(errors)}; {output}")
    for error in errors[:30]:
        print(' - ' + error)
    return 0 if not errors else 1


if __name__ == '__main__':
    raise SystemExit(main())
