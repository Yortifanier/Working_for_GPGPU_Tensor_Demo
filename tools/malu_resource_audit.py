"""Inspect elaborated RTL resources without claiming technology-mapped PPA."""
from pathlib import Path
import argparse
import json
import re
import xml.etree.ElementTree as ET

def constant(text):
    match=re.fullmatch(r"\d+'s?([hdb])([0-9a-fA-F_]+)",text)
    if not match:raise ValueError('Unexpected elaborated constant: '+text)
    return int(match.group(2).replace('_',''),{'h':16,'d':10,'b':2}[match.group(1)])

def audit_xml(path,fp64):
    tree=ET.parse(path)
    types={n.get('id'):n for n in tree.findall('.//typetable/*')}
    variables={n.get('name'):n for n in tree.findall('.//var')}
    def width(dtype):
        d=types[dtype]
        return abs(int(d.get('left','0'))-int(d.get('right','0')))+1
    mem=types[variables['acc_ram'].get('dtype_id')]
    bounds=[constant(n.get('name')) for n in mem.findall('./range/const')]
    depth=abs(bounds[1]-bounds[0])+1
    word_width=width(mem.get('sub_dtype_id'))
    assert depth==(132 if fp64 else 20) and word_width==32,(depth,word_width)
    muls=tree.findall('.//mul')+tree.findall('.//muls')
    numerical=[m for m in muls if {v.get('name') for v in m.findall('.//varref')}=={'mul_lhs','mul_rhs'}]
    variable=[m for m in muls if m.findall('.//varref')]
    assert len(numerical)==1 and len(variable)==1
    operand_widths=[width(variables[n].get('dtype_id')) for n in ['mul_lhs','mul_rhs']]
    # Continuous-assignment aliases may be removed by elaboration. Inspect the
    # multiplication expression's type, not an optional intermediate wire.
    result_width=width(numerical[0].get('dtype_id'))
    add_width=width(variables['add_result'].get('dtype_id'))
    mul_width=53 if fp64 else 24
    assert operand_widths==[mul_width,mul_width] and result_width==2*mul_width and add_width==33
    return {'variable_multiplication_nodes':1,'multiplier_operand_bits':operand_widths,
            'multiplier_result_bits':result_width,'shared_word_add_result_bits':add_width,
            'accumulator_words':depth,'accumulator_word_bits':word_width,
            'accumulator_bits':depth*word_width,
            'claim':'Elaborated RTL, not mapped DSP count, RAM macro, area, frequency, or power sign-off'}

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('xml',type=Path);p.add_argument('--fp64',type=int,choices=[0,1],required=True)
    a=p.parse_args();print(json.dumps(audit_xml(a.xml,bool(a.fp64)),indent=2))
