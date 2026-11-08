#!/usr/bin/env python3
"""Build the vplan reading copy; reuse shared layout, never execute tests."""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from datetime import datetime
from zipfile import ZipFile
from xml.etree import ElementTree as ET
from zoneinfo import ZoneInfo

from docx import Document
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.oxml import OxmlElement
from docx.oxml.ns import qn
from docx.shared import Pt

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[3]
DEPENDENCY=REPO/'docs/sm/build_doc.py'
BUILD=REPO/'build/sm_instr_gen_vplan/v1.0'
NAME='SM_Instruction_Generator_Vplan_v1.0'
FIGURES=['01_generation_and_checking','02_state_and_replay']
spec=importlib.util.spec_from_file_location('_vplan_document_layout',DEPENDENCY)
layout=importlib.util.module_from_spec(spec);spec.loader.exec_module(layout)


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def front_matter(doc,title,date,version='1.0',figure_count=2):
    prefix=[];anchors=[]
    existing=doc._element.xpath('.//w:bookmarkStart')
    next_id=max([int(n.get(qn('w:id'))) for n in existing]+[0])+1
    for i,p in enumerate(p for p in doc.paragraphs if p.style.name=='Heading 1'):
        name=f'sig_vplan_section_{i+1}'
        start=OxmlElement('w:bookmarkStart');start.set(qn('w:id'),str(next_id+i));start.set(qn('w:name'),name)
        end=OxmlElement('w:bookmarkEnd');end.set(qn('w:id'),str(next_id+i))
        p._p.insert(0,start);p._p.append(end);anchors.append((p.text,name))
    def para(text='',size=10.5,color=layout.GRAY,bold=False,after=8):
        p=doc.add_paragraph();p.paragraph_format.space_after=Pt(after)
        layout.font(p.add_run(text),size,bold,color);prefix.append(p._p);return p
    para('VERIFICATION PLAN / SM INSTRUCTION GENERATOR',11,layout.TEAL,True,22).paragraph_format.space_before=Pt(55)
    para(title,27,layout.NAVY,True,18)
    para('SM Instruction Generator Verification Plan',14,layout.TEAL,False,22)
    para(f'版本 {version}  ·  {date}',11,after=16)
    para('计划内容：特性、刺激、独立检查、覆盖目标、阶段和验收条件。',10.5,after=12)
    para('所有动态 testpoint：PLANNED / NOT_RUN。P0 只检查计划静态完整性。',11,layout.TEAL,True,12)
    para('本文件不证明发生器、参考模型、SM RTL 或 SoC 测试已经实现或执行。',10.5,after=8)
    if figure_count:para(f'附 {figure_count} 张流程图与可点击章节导航。',10.5,after=8)
    para().add_run().add_break(WD_BREAK.PAGE)
    para('阅读导航',18,layout.NAVY,True,14).paragraph_format.keep_with_next=True
    for label,anchor in anchors:
        p=para(after=3.5);p.paragraph_format.line_spacing=Pt(18)
        layout.add_internal_link(p,label,anchor)
    para().add_run().add_break(WD_BREAK.PAGE)
    for i,node in enumerate(prefix):doc._body._body.remove(node);doc._body._body.insert(i,node)


def configure(doc,title,date,captions):
    # A private imported module supplies tables/fonts/math/images. Its cover
    # hook is replaced before formatting; the SM architecture cover is not used.
    layout.add_front_matter=front_matter
    layout.configure(doc,title,date,captions,'1.0')
    for section in doc.sections:
        for p in section.header.paragraphs:p.clear()
        layout.font(section.header.paragraphs[0].add_run('SM INSTRUCTION GENERATOR  /  VERIFICATION PLAN'),8.5,color=layout.GRAY)
        for p in section.footer.paragraphs:p.clear()
        p=section.footer.paragraphs[0];p.alignment=WD_ALIGN_PARAGRAPH.RIGHT
        layout.font(p.add_run('VPLAN 1.0  ·  '),8.5,color=layout.GRAY);layout.add_field(p,'PAGE')
    doc.core_properties.title=title
    doc.core_properties.subject='SM Instruction Generator Verification Plan; all dynamic testpoints NOT_RUN'
    doc.core_properties.author='SM 指令发生器验证计划'
    doc.core_properties.keywords='vplan, SM, instruction generator, PLANNED, NOT_RUN, static plan checks'


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',type=Path,default=ROOT/'SM_INSTR_GEN_VPLAN.md')
    parser.add_argument('--date',default=datetime.now(ZoneInfo('Asia/Shanghai')).date().isoformat())
    parser.add_argument('--version',choices=['1.0'],default='1.0')
    parser.add_argument('--render-check',action='store_true')
    parser.add_argument('--no-figures',action='store_true',help='Require zero figures instead of the two planned flow diagrams')
    parser.add_argument('--soffice')
    args=parser.parse_args();source=args.source.resolve();source_bytes=source.read_bytes();dependency_sha=sha(DEPENDENCY)
    BUILD.mkdir(parents=True,exist_ok=True)
    for directory in [BUILD/'cache',BUILD/'config']:directory.mkdir(exist_ok=True)
    env=dict(os.environ,XDG_CACHE_HOME=str(BUILD/'cache'),XDG_CONFIG_HOME=str(BUILD/'config'))
    qa_path=BUILD/'document_qa.json'
    qa_path.write_text(json.dumps({'passed':False,'status':'building','dynamic_testpoints_executed':0})+'\n')
    pandoc=layout.executable('pandoc')
    ast=json.loads(subprocess.check_output([pandoc,'-f','gfm+tex_math_dollars+implicit_figures','-t','json'],input=source_bytes,cwd=ROOT,env=env))
    native_breaks=0
    for node in layout.walk(ast['blocks']):
        if node['t']=='RawInline' and node['c'][0]=='html' and re.fullmatch(r'<br\s*/?>',node['c'][1],re.I):
            node.clear();node['t']='LineBreak';native_breaks+=1
    title='SM 指令发生器验证计划'
    if ast['blocks'] and ast['blocks'][0]['t']=='Header' and ast['blocks'][0]['c'][0]==1:
        title=layout.plain(ast['blocks'].pop(0)['c'][2])
    headings=[n for n in layout.walk(ast['blocks']) if n['t']=='Header']
    if headings:
        offset=min(n['c'][0] for n in headings)-1
        for node in headings:node['c'][0]-=offset
    figures=[] if args.no_figures else FIGURES
    images=[n for n in layout.walk(ast['blocks']) if n['t']=='Image']
    if len(images)!=len(figures) or {Path(n['c'][2][0]).stem for n in images}!=set(figures):
        raise RuntimeError(f'Source must reference each of the {len(figures)} expected figures exactly once')
    for image in images:
        path=Path(image['c'][2][0])
        if path.suffix.lower()=='.svg' and (ROOT/path.with_suffix('.png')).is_file():image['c'][2][0]=str(path.with_suffix('.png'))
    figure_hashes={n['c'][2][0]:sha(ROOT/n['c'][2][0]) for n in images}
    captions=[layout.plain(n['c'][1]) for n in images]
    expected_math=sum(n['t']=='Math' for n in layout.walk(ast['blocks']))
    expected_tables=sum(n['t']=='Table' for n in layout.walk(ast['blocks']))
    ast_path=BUILD/'vplan_ast.json';ast_path.write_text(json.dumps(ast,ensure_ascii=False))
    body=BUILD/'body.docx'
    subprocess.run([pandoc,str(ast_path),'-f','json','-t','docx','--resource-path',str(ROOT),'-o',str(body)],cwd=ROOT,env=env,check=True)
    doc=Document(body);configure(doc,title,args.date,captions)
    destination=ROOT/(NAME+'.docx');doc.save(destination)
    with ZipFile(destination) as package:
        xml=ET.fromstring(package.read('word/document.xml'))
        media=[n for n in package.namelist() if n.startswith('word/media/')]
        tables=len(xml.findall('.//w:tbl',layout.NS));math=len(xml.findall('.//m:oMath',layout.NS))
        nav=sum((n.get(qn('w:anchor')) or '').startswith('sig_vplan_section_') for n in xml.findall('.//w:hyperlink',layout.NS))
        assert tables==expected_tables and math==expected_math and nav==sum(n['c'][0]==1 for n in headings)
        assert len(media)==len(figures)
        assert {hashlib.sha256(package.read(n)).hexdigest() for n in media}==set(figure_hashes.values())
        assert '\ufffd' not in package.read('word/document.xml').decode()
    export=BUILD/('pdf_export_'+datetime.now().strftime('%Y%m%d_%H%M%S_%f'));export.mkdir()
    profile=BUILD/'libreoffice-profile'
    result=subprocess.run([layout.executable('soffice',args.soffice),'-env:UserInstallation='+profile.as_uri(),'--headless','--convert-to','pdf:writer_pdf_Export','--outdir',str(export),str(destination)],cwd=ROOT,env=env,text=True,capture_output=True,timeout=180)
    (BUILD/'pdf_export.log').write_text(result.stdout+result.stderr);result.check_returncode()
    generated_pdf=export/(NAME+'.pdf')
    if not generated_pdf.is_file() or generated_pdf.stat().st_size<1000:raise RuntimeError('Fresh PDF export missing')
    pdf=ROOT/generated_pdf.name;shutil.copy2(generated_pdf,pdf)
    info=subprocess.check_output([layout.executable('pdfinfo'),str(pdf)],text=True)
    pages=int(re.search(r'^Pages:\s+(\d+)',info,re.M)[1]);text_path=BUILD/'pdf_text.txt'
    subprocess.run([layout.executable('pdftotext'),'-layout',str(pdf),str(text_path)],check=True)
    text=text_path.read_text();assert '\ufffd' not in text and '¿' not in text
    assert all(layout.normalized(layout.plain(n['c'][2])) in layout.normalized(text) for n in headings)
    import fitz
    with fitz.open(pdf) as rendered:
        links=sum(link['kind']==fitz.LINK_GOTO for page in rendered for link in page.get_links())
        unique_images=len({im[0] for page in rendered for im in page.get_images()})
        outside=[[i,word[4]] for i,page in enumerate(rendered,1) for word in page.get_text('words') if word[0]<-1 or word[1]<-1 or word[2]>page.rect.width+1 or word[3]>page.rect.height+1]
        assert links>=nav and unique_images==len(figures) and not outside
    rendered_pages=[]
    if args.render_check:
        selected={1,pages};page_texts=text.split('\f')
        for caption in captions:
            token=layout.normalized(caption)[:24]
            match=next((i+1 for i,page in enumerate(page_texts) if token and token in layout.normalized(page)),None)
            if match:selected.add(match)
        for i in sorted(selected):
            prefix=BUILD/f'page_{i:02d}'
            subprocess.run([layout.executable('pdftoppm'),'-f',str(i),'-l',str(i),'-singlefile','-scale-to','1600','-png',str(pdf),str(prefix)],check=True)
            rendered_pages.append(str(prefix.with_suffix('.png').relative_to(REPO)))
    assert source.read_bytes()==source_bytes and sha(DEPENDENCY)==dependency_sha
    assert all(sha(ROOT/path)==digest for path,digest in figure_hashes.items())
    qa={'passed':True,'status':'complete','check_kind':'DOCUMENT_BUILD_QA','scope':'Document structure and rendering, not generator or DUT test execution.',
        'dynamic_testpoints_executed':0,'dynamic_execution':'NOT_RUN','title':title,'build_date':args.date,'version':'1.0',
        'source':str(source.relative_to(REPO)),'source_sha256':hashlib.sha256(source_bytes).hexdigest(),
        'docx':str(destination.relative_to(REPO)),'docx_sha256':sha(destination),'pdf':str(pdf.relative_to(REPO)),'pdf_sha256':sha(pdf),
        'layout_dependency':{'path':str(DEPENDENCY.relative_to(REPO)),'sha256':dependency_sha},
        'native_tables':tables,'native_math':math,'embedded_images':len(media),'chapter_navigation_links':nav,'html_breaks_converted_to_native':native_breaks,
        'pdf_pages':pages,'pdf_text_characters':len(text),'all_heading_text_found':True,
        'pdf_structural_check':{'internal_links':links,'unique_images':unique_images,'text_outside_page_bounds':outside},
        'figure_sha256':figure_hashes,'source_and_figures_unchanged_during_build':True,'rendered_pages':rendered_pages}
    qa_path.write_text(json.dumps(qa,ensure_ascii=False,indent=2)+'\n');print(json.dumps(qa,ensure_ascii=False,indent=2))


if __name__=='__main__':main()
