#!/usr/bin/env python3
"""Check vplan metadata and trace fidelity; never run a generator or DUT test."""
from __future__ import annotations
import argparse
import csv
import hashlib
import json
import re
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[3]
PHASES={'P0_PLAN_STATIC','P1_GENERATOR_UNIT','P2_REFERENCE_PROGRAM','P3_SM_RTL','P4_SOC'}
GEN_STAGES={'GENERATED','LEGALIZED','REJECTED','CHECKED'}
DUT_STAGES={'ADMITTED','COMPLETED','CHECKED','REPORT_CLASSIFIED','REJECTED'}


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(plan_dir):
    errors=[];inputs={};counts={};source_hashes={}
    def check(condition,message):
        if not condition:errors.append(message)
    def read(name,schema_name):
        path=plan_dir/name
        try:data=json.loads(path.read_text())
        except (OSError,ValueError) as exc:
            errors.append(f'{name}: {exc}');return None
        inputs[name]=sha(path)
        schema=json.loads((ROOT/'schemas'/schema_name).read_text())
        validator=Draft202012Validator(schema,format_checker=FormatChecker())
        failures=sorted(validator.iter_errors(data),key=lambda e:str(list(e.absolute_path)))
        for failure in failures:
            errors.append(f'{name}:{"/".join(map(str,failure.absolute_path))}: {failure.message}')
        return data if not failures else None
    def repo_path(value):
        path=(REPO/value).resolve()
        if Path(value).is_absolute() or not path.is_relative_to(REPO):
            raise ValueError('source path must stay relative to the repository: '+value)
        return path
    def inventory(record):
        try:
            path=repo_path(record['path']);actual=sha(path)
            check(actual==record['sha256'],'source SHA256 mismatch: '+record['path'])
            source_hashes[record['path']]=actual
            return json.loads(path.read_text())
        except (OSError,ValueError,KeyError) as exc:
            errors.append('source inventory: '+str(exc));return None
    def refs(values,label):
        for value in values:
            try:
                path,anchor=value.split('#',1)
                check(bool(anchor) and repo_path(path).is_file(),f'{label}: missing source ref {value}')
            except ValueError as exc:errors.append(f'{label}: {exc}')
    features=read('vplan_features.json','vplan_features.schema.json')
    tests=read('testpoints.json','testpoints.schema.json')
    traces=[(read('instruction_traceability.json','trace.schema.json'),'instruction_traceability',217,'instruction_topics'),
            (read('special_register_traceability.json','trace.schema.json'),'special_register_traceability',35,'special_register_topics')]
    if features is None or tests is None or any(t[0] is None for t in traces):
        return errors,counts,inputs,source_hashes
    phase_ids=[p if isinstance(p,str) else p['id'] for p in features['phases']]
    check(len(set(phase_ids))==len(phase_ids) and set(phase_ids)==PHASES,'phase declarations must cover the five unique PHASE_IDS')
    check(features['source_inventory']==tests['source_inventory'],'features/testpoints source inventories differ')
    for key in ('version','date'):
        if key in tests:check(features[key]==tests[key],f'features/testpoints {key} differs')
    for record in features['source_inventory'].values():
        try:
            path=repo_path(record['path']);actual=sha(path)
            check(actual==record['sha256'],'source SHA256 mismatch: '+record['path'])
            source_hashes[record['path']]=actual
        except (OSError,ValueError) as exc:errors.append('source inventory: '+str(exc))
    fmap={};tmap={};cmap={}
    for f in features['features']:
        check(f['id'] not in fmap,'duplicate feature ID: '+f['id']);fmap[f['id']]=f
        refs(f['source_refs'],f['id'])
        for cv in f['coverage_points']:
            check(cv['id'] not in cmap,'duplicate coverage ID: '+cv['id']);cmap[cv['id']]=(f['id'],cv)
            stages=GEN_STAGES if cv['scope']=='GENERATOR' else DUT_STAGES
            check(cv['sample_stage'] in stages,f"{cv['id']}: stage does not match {cv['scope']} scope")
    used_cv=set()
    for t in tests['testpoints']:
        tid=t['id'];check(tid not in tmap,'duplicate test ID: '+tid);tmap[tid]=t
        refs(t.get('source_refs',[]),tid)
        for fid in t['feature_ids']:
            check(fid in fmap,f'{tid}: unknown feature {fid}')
            if fid in fmap:
                check(tid in fmap[fid]['test_ids'],f'{tid}: reverse feature.test_ids link missing for {fid}')
                check(t['phase'] in fmap[fid]['phases'],f'{tid}: phase is absent from {fid}')
        if t['phase']=='P0_PLAN_STATIC':
            check(not t['coverage_ids'],f'{tid}: P0 cannot sample dynamic coverage')
        else:check(bool(t['coverage_ids']),f'{tid}: no coverage IDs')
        for cid in t['coverage_ids']:
            check(cid in cmap,f'{tid}: unknown coverage {cid}');used_cv.add(cid)
            if cid in cmap:
                owner,cv=cmap[cid]
                check(owner in t['feature_ids'],f'{tid}: coverage owner {owner} missing from feature_ids')
                if cv['scope']=='DUT_SCENARIO':
                    check(t['phase'] in {'P3_SM_RTL','P4_SOC'},f'{tid}: DUT_SCENARIO coverage requires P3/P4')
        if t['phase'] in {'P3_SM_RTL','P4_SOC'}:
            check(bool(t.get('dependency_gate')) or any(fmap.get(fid,{}).get('dependency_gate') for fid in t['feature_ids']),f'{tid}: future DUT scenario needs an explicit dependency_gate')
    for f in fmap.values():
        for tid in f['test_ids']:
            check(tid in tmap,f"{f['id']}: unknown test {tid}")
            if tid in tmap:check(f['id'] in tmap[tid]['feature_ids'],f"{f['id']}: reverse test.feature_ids link missing for {tid}")
    check(used_cv==set(cmap),'unreferenced coverage IDs: '+','.join(sorted(set(cmap)-used_cv)))
    all_sections=set();all_trace_ids=set()
    for trace,name,expected,topic_key in traces:
        entries=trace['entries'];check(len(entries)==expected,f'{name}: expected {expected} entries')
        source_rows={};pdf_sources=[]
        for record in trace['source_inventories']:
            src=inventory(record)
            if src:
                source_rows.update({e['section']:e for e in src.get(topic_key,[])})
                pdf_sources.append(src['source'])
        check(set(source_rows)=={e['section'] for e in entries},f'{name}: trace/source section sets differ')
        for src in pdf_sources:
            for key in ('file_name','sha256','release'):
                check(src[key]==trace['source_pdf'][key],f'{name}: source PDF {key} mismatch')
        for e in entries:
            section=e['section'];eid=e['trace_id']
            check(section not in all_sections,f'duplicate source section: {section}');all_sections.add(section)
            check(eid not in all_trace_ids,f'duplicate trace ID: {eid}');all_trace_ids.add(eid)
            refs(e['source_refs'],eid)
            for fid in [e['primary_feature_id'],*e['related_feature_ids']]:check(fid in fmap,f'{eid}: unknown feature {fid}')
            src=source_rows.get(section)
            if src:
                names=src.get('heading_mnemonics') if topic_key=='instruction_topics' else [v.strip() for v in src['register_heading_label'].split(',')]
                for key,value in [('names',names),('pdf_page_start',src['pdf_page_start']),('printed_page_start',src['printed_page_start'])]:
                    check(e[key]==value,f'{eid}: source {key} mismatch')
                if topic_key=='instruction_topics':
                    check(e['entry_kind']==src['entry_kind'],f'{eid}: entry_kind mismatch')
                    check(e['domain']==src['suggested_sm_execution_domain']['id'],f'{eid}: source domain mismatch')
                    check(e['domain_description']==src['suggested_sm_execution_domain']['description_zh'],f'{eid}: source domain description mismatch')
                else:
                    check(e['entry_kind']=='special_register_description',f'{eid}: special-register kind mismatch')
                    check(e['domain_description']==src['suggested_sm_state_provider_zh'],f'{eid}: source state provider mismatch')
                if 'is_executable_instruction_description' in e:
                    check(e['is_executable_instruction_description']==(e['entry_kind']=='instruction'),f'{eid}: instruction-description classification mismatch')
                check(any(ref==record['path']+'#'+section for record in trace['source_inventories'] for ref in e['source_refs']),f'{eid}: exact inventory#section source ref missing')
        csv_path=plan_dir/(name+'.csv')
        try:
            with csv_path.open(newline='') as stream:rows=list(csv.DictReader(stream))
            inputs[csv_path.name]=sha(csv_path)
            check(len(rows)==len(entries),f'{name}: CSV/JSON row count mismatch')
            byid={row['trace_id']:row for row in rows}
            check(len(byid)==len(rows),f'{name}: duplicate CSV trace_id')
            for e in entries:
                row=byid.get(e['trace_id'],{})
                check(set(row)==set(e),f"{e['trace_id']}: CSV/JSON columns differ")
                for key,value in e.items():
                    if key not in row:continue
                    actual=json.loads(row[key]) if isinstance(value,(list,dict,bool)) else (None if value is None and row[key]=='' else row[key])
                    expected_value=str(value) if isinstance(value,int) and not isinstance(value,bool) else value
                    check(actual==expected_value,f"{e['trace_id']}: CSV/JSON cell differs: {key}")
        except (OSError,ValueError,KeyError) as exc:errors.append(f'{name} CSV: {exc}')
        counts[name]=len(entries)
    counts.update(features=len(fmap),testpoints=len(tmap),coverage_points=len(cmap),source_sections=len(all_sections))
    markdown=plan_dir/'SM_INSTR_GEN_VPLAN.md'
    try:
        text=markdown.read_text();inputs[markdown.name]=sha(markdown)
        for label,pattern,expected in [('features',r'(?<![A-Za-z0-9_-])GEN-[A-Z0-9_-]+(?![A-Za-z0-9_-])',set(fmap)),
                                        ('tests',r'(?<![A-Za-z0-9_-])SIG-[A-Z0-9_-]+-[0-9]{3}(?![A-Za-z0-9_-])',set(tmap)),
                                        ('coverage',r'(?<![A-Za-z0-9_-])CV-[A-Z0-9_-]+-[0-9]{3}(?![A-Za-z0-9_-])',set(cmap))]:
            found=set(re.findall(pattern,text))
            check(found==expected,f'Markdown {label}: missing={sorted(expected-found)}, unknown={sorted(found-expected)}')
        check('NOT_RUN' in text,'Markdown must state NOT_RUN explicitly')
    except OSError as exc:errors.append('Markdown: '+str(exc))
    return errors,counts,inputs,source_hashes


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan-dir',type=Path,default=ROOT)
    parser.add_argument('--output',type=Path)
    args=parser.parse_args();plan_dir=args.plan_dir.resolve()
    errors,counts,inputs,sources=run(plan_dir)
    report={'check_kind':'PLAN_STATIC_CHECK','result':'FAIL' if errors else 'PASS','passed':not errors,
            'scope':'Schema, source fidelity and planning associations only; not generator, reference-model, adapter or DUT execution.',
            'dynamic_execution':'NOT_RUN','dynamic_testpoints_executed':0,'counts':counts,'input_sha256':inputs,
            'source_inventory_sha256':sources,'checker_sha256':sha(Path(__file__)),
            'schema_sha256':{p.name:sha(p) for p in sorted((ROOT/'schemas').glob('*.json'))},'errors':errors}
    output=args.output or plan_dir/'reports/vplan_static_check.json';output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(f"Plan static check {report['result']}; dynamic tests NOT_RUN; errors={len(errors)}; {output}")
    for error in errors[:30]:print(' - '+error)
    return 0 if not errors else 1


if __name__=='__main__':raise SystemExit(main())
