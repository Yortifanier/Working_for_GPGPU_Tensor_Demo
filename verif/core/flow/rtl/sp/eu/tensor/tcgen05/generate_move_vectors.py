"""Independent Python/IEEE oracle for load reduction and 2:4 selection."""
from pathlib import Path
from functools import cmp_to_key
import argparse
import json
import math
import random
import struct

def f32(bits):
    return struct.unpack('<f',struct.pack('<I',bits))[0]

def nan(bits):
    return math.isnan(f32(bits))

def red(a,b,kind,maximum,absolute,propagate):
    if kind:
        av=a-(1<<32) if kind==1 and a>>31 else a
        bv=b-(1<<32) if kind==1 and b>>31 else b
        return a if ((av>bv) if maximum else (av<bv)) else b
    if absolute:
        a &= 0x7fffffff; b &= 0x7fffffff
    if nan(a) and nan(b) or propagate and (nan(a) or nan(b)):
        return 0x7fc00000
    if nan(a): return b
    if nan(b): return a
    av,bv=f32(a),f32(b)
    if av==bv==0:
        return ((a & b) if maximum else (a | b)) & 0x80000000
    return a if ((av>bv) if maximum else (av<bv)) else b

def compress(values,maximum,absolute):
    def compare(i,j):
        ni,nj=nan(values[i]),nan(values[j])
        if ni!=nj: return -1 if ni else 1
        if ni: return -1 if i<j else 1
        a,b=f32(values[i]),f32(values[j])
        if absolute: a,b=abs(a),abs(b)
        if a==b:
            if a==0 and not absolute and (values[i]^values[j])>>31:
                prefer=not (values[i]>>31) if maximum else bool(values[i]>>31)
                return -1 if prefer else 1
            return -1 if i<j else 1
        return -1 if ((a>b) if maximum else (a<b)) else 1
    chosen=sorted(sorted(range(4),key=cmp_to_key(compare))[:2])
    return values[chosen[0]],values[chosen[1]],chosen[0]|(chosen[1]<<2)

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out',required=True,type=Path)
    p.add_argument('--seed',type=int,default=1907)
    p.add_argument('--count',type=int,default=6000)
    args=p.parse_args(); rng=random.Random(args.seed)
    special=[0,0x80000000,1,0x80000001,0x007fffff,0x807fffff,
             0x00800000,0x80800000,0x3f800000,0xbf800000,
             0x7f7fffff,0xff7fffff,0x7f800000,0xff800000,
             0x7fc00000,0xffc00001,0x7f800001,0xffffffff,0x80000001]
    vectors=[]
    for index in range(args.count):
        kind=index%3; maximum=bool((index//3)&1)
        absolute=bool((index//6)&1) if not kind else False
        propagate=bool((index//12)&1) if not kind else False
        values=[rng.choice(special) if index%3 else rng.getrandbits(32) for _ in range(6)]
        a,b,*sp=values
        expected=red(a,b,kind,maximum,absolute,propagate)
        c0,c1,meta=compress(sp,maximum,absolute)
        fields=[a,b,kind,int(maximum),int(absolute),int(propagate),*sp,expected,c0,c1,meta]
        vectors.append(' '.join(f'{v:08x}' for v in fields))
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text('\n'.join(vectors)+'\n')
    args.out.with_suffix('.json').write_text(json.dumps({'oracle':'Python float decoding plus explicit IEEE NaN/signed-zero rules; source-order compression','seed':args.seed,'vectors':len(vectors)},indent=2)+'\n')
    print(f'Generated {len(vectors)} move comparison vectors')

if __name__=='__main__':main()
