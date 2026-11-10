#!/usr/bin/env python3
"""Build the execution-level testplan reading copy; never run planned cases."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import re
import sys

from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Cm, Pt

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[3]
DEPENDENCY = REPO / 'verif/core/vplan/sm_instr_gen/build_doc.py'
spec = importlib.util.spec_from_file_location('_testplan_reading_copy', DEPENDENCY)
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
layout = engine.layout
engine.ROOT = ROOT
engine.BUILD = REPO / 'build/sm_instr_gen_testplan/v1.0'
engine.NAME = 'SM_Instruction_Generator_Testplan_v1.0'
engine.FIGURES = ['01_case_execution_checkpoints', '02_campaign_gates_and_evidence']
engine.__doc__ = __doc__
original_configure = engine.configure


def front_matter(doc, title, date, version='1.0', figure_count=2):
    prefix, anchors = [], []
    existing = doc._element.xpath('.//w:bookmarkStart')
    next_id = max([int(n.get(qn('w:id'))) for n in existing] + [0]) + 1
    # The reused engine checks this internal namespace; it has no cross-document links.
    for i, p in enumerate(p for p in doc.paragraphs if p.style.name == 'Heading 1'):
        name = f'sig_vplan_section_{i+1}'
        start, end = OxmlElement('w:bookmarkStart'), OxmlElement('w:bookmarkEnd')
        start.set(qn('w:id'), str(next_id+i)); start.set(qn('w:name'), name)
        end.set(qn('w:id'), str(next_id+i))
        p._p.insert(0, start); p._p.append(end); anchors.append((p.text, name))

    def para(text='', size=10.5, color=layout.GRAY, bold=False, after=8):
        p = doc.add_paragraph(); p.paragraph_format.space_after = Pt(after)
        layout.font(p.add_run(text), size, bold, color); prefix.append(p._p)
        return p

    para('EXECUTION-LEVEL TESTPLAN / SM INSTRUCTION GENERATOR', 10.5, layout.TEAL, True, 22).paragraph_format.space_before = Pt(55)
    para(title, 27, layout.NAVY, True, 18)
    para('SM Instruction Generator Testplan', 14, layout.TEAL, after=22)
    para(f'版本 {version}  ·  {date}', 11, after=16)
    para('执行级计划：参数、初态、步骤、检查点、通过条件、suite、门禁和失败证据。', 10.5, after=12)
    para('所有 Generator / SM 动态测试：NOT_RUN；实现门禁尚未打开。', 11, layout.TEAL, True, 12)
    para('P0 只检查计划静态一致性；不运行发生器、runner、adapter、模型或 DUT。', 10.5, after=8)
    if figure_count:
        para(f'附 {figure_count} 张逻辑流程图与可点击章节导航。', after=8)
    para().add_run().add_break(WD_BREAK.PAGE)
    para('阅读导航', 18, layout.NAVY, True, 14).paragraph_format.keep_with_next = True
    for label, anchor in anchors:
        p = para(after=3.5); p.paragraph_format.line_spacing = Pt(18)
        layout.add_internal_link(p, label, anchor)
    para().add_run().add_break(WD_BREAK.PAGE)
    for i, node in enumerate(prefix):
        doc._body._body.remove(node); doc._body._body.insert(i, node)


def configure(doc, title, date, captions):
    engine.front_matter = front_matter
    original_configure(doc, title, date, captions)
    # Case field labels need less space than full parameters and checkpoint text.
    # Keep the shared 9 pt table font and all other table layouts unchanged.
    for table in doc.tables:
        if len(table.columns) != 2 or not re.fullmatch(r'TC-[A-Z0-9_-]+-[0-9]{3}\s+项目', table.cell(0, 0).text.strip()):
            continue
        for column, width in zip(table.columns, [3.7, 13.3]):
            column.width = Cm(width)
        for row in table.rows:
            for cell, width in zip(row.cells, [3.7, 13.3]):
                cell.width = Cm(width)
    for section in doc.sections:
        for p in section.header.paragraphs:
            p.clear()
        layout.font(section.header.paragraphs[0].add_run('SM INSTRUCTION GENERATOR  /  EXECUTION-LEVEL TESTPLAN'), 8, color=layout.GRAY)
        for p in section.footer.paragraphs:
            p.clear()
        p = section.footer.paragraphs[0]; p.alignment = WD_ALIGN_PARAGRAPH.RIGHT
        layout.font(p.add_run('TESTPLAN 1.0  ·  '), 8.5, color=layout.GRAY); layout.add_field(p, 'PAGE')
    doc.core_properties.title = title
    doc.core_properties.subject = 'SM Instruction Generator Testplan; all dynamic cases NOT_RUN'
    doc.core_properties.author = 'SM 指令发生器执行级测试计划'
    doc.core_properties.keywords = 'testplan, SM, instruction generator, checkpoints, NOT_RUN, static checks'


def main():
    dependencies = [DEPENDENCY, REPO / 'docs/sm/build_doc.py']
    before = {str(p.relative_to(REPO)): engine.sha(p) for p in dependencies}
    engine.configure = configure
    if not any(a == '--source' or a.startswith('--source=') for a in sys.argv[1:]):
        sys.argv += ['--source', str(ROOT / 'SM_INSTR_GEN_TESTPLAN.md')]
    engine.main()
    assert all(engine.sha(REPO / path) == digest for path, digest in before.items())
    path = engine.BUILD / 'document_qa.json'
    qa = json.loads(path.read_text())
    qa['layout_dependencies'] = before
    qa['testplan_builder_sha256'] = engine.sha(Path(__file__))
    qa['scope'] = 'Execution-level testplan document structure and rendering only; no runner, generator, model, adapter or DUT execution.'
    path.write_text(json.dumps(qa, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
