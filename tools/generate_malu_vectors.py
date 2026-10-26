"""Independent exact-rational test vectors for the SystemVerilog MALU testbench.

No segmented accumulator, DUT decoder calls, host floating-point, or DPI are
used here. Quotient/remainder rounding is independent of the RTL G/R/S scan.
Generated vectors and manifests belong in ignored build directories.
"""
from __future__ import annotations
from dataclasses import dataclass
from fractions import Fraction
from pathlib import Path
import argparse
import json
import random

F16,BF16,TF32,F32,F64,E4M3,E5M2,E2M3,E3M2,E2M1,S8,U8,S4,U4,TI16,B1,S32 = range(17)
NONE,UE8M0,UE4M3,UE5M3 = range(4)
RNE,RTZ,RDN,RUP = range(4)
OK,BAD_CFG,BAD_ENCODING,LENGTH,UNSUPPORTED,RANGE = range(6)
SPECS = {F16:(16,5,10,15), BF16:(16,8,7,127), TF32:(32,8,10,127),
         F32:(32,8,23,127), F64:(64,11,52,1023), E4M3:(8,4,3,7),
         E5M2:(8,5,2,15), E2M3:(6,2,3,1), E3M2:(6,3,2,3), E2M1:(4,2,1,1)}
WIDTHS = {**{f:s[0] for f,s in SPECS.items()}, S8:8,U8:8,S4:4,U4:4,TI16:16,B1:1,S32:32}
NAMES = dict(enumerate(['F16','BF16','TF32','F32','F64','E4M3','E5M2','E2M3','E3M2','E2M1','S8','U8','S4','U4','TI16','B1','S32']))
FIELDS = [('a_fmt',5),('b_fmt',5),('c_fmt',5),('d_fmt',5),
          ('a_scale_fmt',2),('b_scale_fmt',2),('block_scale_en',1),('block_size',1),
          ('a_block_offset',5),('b_block_offset',5),('k',16),('rounding',2),
          ('int_sat',1),('binary_xor',1),('ti16_decoded',1),('c_scale_shift',4),('profile',2)]

def power(n):
    return Fraction(1 << n) if n >= 0 else Fraction(1,1 << -n)

@dataclass
class Value:
    kind: str = 'finite'
    value: Fraction = Fraction(0)
    sign: bool = False

def decode(fmt, raw, ti16=True):
    if fmt not in SPECS:
        width=WIDTHS[fmt]; n=raw & ((1<<width)-1)
        if fmt in (S8,S4,TI16,S32) and n & (1<<(width-1)): n-=1<<width
        if fmt == TI16 and (not ti16 or not -2047 <= n <= 2047): raise ValueError('ti16 encoding')
        return Value(value=Fraction(n),sign=n<0)
    width,eb,fb,bias=SPECS[fmt]; raw &= (1<<width)-1; sign=bool(raw>>(width-1))
    if fmt == TF32:
        if raw & 8191: raise ValueError('TF32 low bits')
        exponent=(raw>>23)&255; fraction=(raw>>13)&1023
    else:
        exponent=(raw>>fb)&((1<<eb)-1); fraction=raw&((1<<fb)-1)
    if fmt in (F16,BF16,TF32,F32,F64,E5M2) and exponent == (1<<eb)-1:
        return Value('nan' if fraction else 'inf',sign=sign)
    if fmt == E4M3 and exponent==15 and fraction==7: return Value('nan',sign=sign)
    coefficient=fraction if exponent==0 else (1<<fb)+fraction
    number=coefficient*power((1 if exponent==0 else exponent)-bias-fb)
    return Value(value=-number if sign else number,sign=sign)

def decode_scale(fmt, raw):
    if fmt==NONE: return Value(value=Fraction(1))
    if fmt==UE8M0:
        return Value('nan') if raw==255 else Value(value=power(raw-127))
    eb,bias=(4,7) if fmt==UE4M3 else (5,15)
    if fmt==UE4M3 and raw&128: raise ValueError('UE4M3 padding')
    if raw==(1<<(eb+3))-1: return Value('nan')
    exponent=raw>>3; fraction=raw&7
    return Value(value=(fraction if exponent==0 else 8+fraction)*power((exponent or 1)-bias-3))

def multiply(a,b):
    sign=a.sign^b.sign
    if a.kind=='nan' or b.kind=='nan': return Value('nan')
    if (a.kind=='inf' and b.kind=='finite' and not b.value) or (b.kind=='inf' and a.kind=='finite' and not a.value):
        return Value('nan')
    if a.kind=='inf' or b.kind=='inf': return Value('inf',sign=sign)
    return Value(value=a.value*b.value,sign=sign)

def floor_log2(q):
    e=q.numerator.bit_length()-q.denominator.bit_length()
    if q<power(e): e-=1
    return e

def encode_result(q, fmt, rounding, negative_zero=False):
    width,eb,fb,bias=SPECS[fmt]
    sign=q<0 or (q==0 and negative_zero); signbit=int(sign)<<(width-1)
    if q==0: return signbit
    q=abs(q); exponent=floor_log2(q)
    quantum=max(exponent-fb,1-bias-fb)
    scaled=q/power(quantum); coefficient,rest=divmod(scaled.numerator,scaled.denominator)
    increment=False
    if rounding==RNE:
        increment=(2*rest>scaled.denominator or (2*rest==scaled.denominator and bool(coefficient&1)))
    elif rounding==RDN: increment=sign and rest!=0
    elif rounding==RUP: increment=not sign and rest!=0
    coefficient+=int(increment)
    if coefficient >= 1<<(fb+1): coefficient>>=1; quantum+=1
    exponent_field=quantum+fb+bias if coefficient >= 1<<fb else 0
    if exponent_field >= (1<<eb)-1:
        inf=rounding==RNE or (rounding==RDN and sign) or (rounding==RUP and not sign)
        return signbit | ((((1<<eb)-1) if inf else (1<<eb)-2)<<fb) | (0 if inf else (1<<fb)-1)
    return signbit | (exponent_field<<fb) | (coefficient & ((1<<fb)-1))

def pack_cfg(c):
    packed=0
    for name,width in FIELDS:
        value=int(c[name]); assert 0<=value<1<<width,(name,value)
        packed=(packed<<width)|value
    assert sum(w for _,w in FIELDS)==63
    return packed

def one(fmt, negative=False):
    width,_,fb,bias=SPECS[fmt]
    result=bias << (23 if fmt==TF32 else fb)
    return result | ((1<<(width-1)) if negative else 0)

def reference(c, c_raw, pairs):
    try:
        cv=decode(c['c_fmt'],c_raw,c['ti16_decoded'])
        if cv.kind=='finite': cv.value*=power(-c['c_scale_shift'])
        terms=[cv]
        for a,b,sa,sb in pairs:
            av=decode(c['a_fmt'],a,c['ti16_decoded']); bv=decode(c['b_fmt'],b,c['ti16_decoded'])
            if c['a_fmt']==B1:
                v=(a^b)&1 if c['binary_xor'] else (a&b)&1
                terms.append(Value(value=Fraction(v)))
            else:
                if c['block_scale_en']:
                    av=multiply(av,decode_scale(c['a_scale_fmt'],sa));bv=multiply(bv,decode_scale(c['b_scale_fmt'],sb))
                terms.append(multiply(av,bv))
    except ValueError:
        return BAD_ENCODING,0
    if c['a_fmt'] not in SPECS:
        n=sum(int(t.value) for t in terms)
        if c['int_sat']: n=max(-(1<<31),min((1<<31)-1,n))
        return OK,n&0xffffffff
    _,eb,fb,_=SPECS[c['d_fmt']]
    if any(t.kind=='nan' for t in terms) or {t.sign for t in terms if t.kind=='inf'}=={True,False}:
        return OK,(((1<<eb)-1)<<fb)|(1<<(fb-1))
    inf=next((t for t in terms if t.kind=='inf'),None)
    if inf is not None:
        return OK,(int(inf.sign)<<(WIDTHS[c['d_fmt']]-1))|(((1<<eb)-1)<<fb)
    q=sum((t.value for t in terms),Fraction(0))
    all_negative_zero=all(t.value==0 and t.sign for t in terms)
    all_positive_zero=all(t.value==0 and not t.sign for t in terms)
    negative_zero=all_negative_zero or (not all_positive_zero and c['rounding']==RDN)
    return OK,encode_result(q,c['d_fmt'],c['rounding'],negative_zero)

class Builder:
    def __init__(self,no_fp64=False): self.cases=[];self.no_fp64=no_fp64
    def add(self,name,a,b,*,a_fmt=F16,b_fmt=None,c_fmt=F32,d_fmt=F32,c=0,sa=None,sb=None,expect=None,**kw):
        assert len(a)==len(b)
        config=dict(a_fmt=a_fmt,b_fmt=a_fmt if b_fmt is None else b_fmt,c_fmt=c_fmt,d_fmt=d_fmt,
                    a_scale_fmt=NONE,b_scale_fmt=NONE,block_scale_en=0,block_size=1,
                    a_block_offset=0,b_block_offset=0,k=len(a),rounding=RNE,int_sat=0,
                    binary_xor=0,ti16_decoded=0,c_scale_shift=0,profile=0)
        config.update(kw)
        pairs=list(zip(a,b,sa if sa is not None else [0]*len(a),sb if sb is not None else [0]*len(a)))
        result=expect if expect is not None else reference(config,c,pairs)
        if self.no_fp64 and F64 in [config[x] for x in ['a_fmt','b_fmt','c_fmt','d_fmt']]: result=(UNSUPPORTED,0)
        self.cases.append(dict(name=name,cfg=config,c=c,pairs=pairs,status=result[0],data=result[1]))

def directed(t):
    for f in SPECS:
        d=F64 if f==F64 else F32
        t.add('ones_'+NAMES[f],[one(f)]*3,[one(f)]*3,a_fmt=f,c_fmt=d,d_fmt=d,c=one(d))
        for rm in range(4):
            t.add('minsub_'+NAMES[f]+'_'+str(rm),[1],[1],a_fmt=f,c_fmt=d,d_fmt=d,rounding=rm)
    for fmt in [F16,BF16,F32,F64]:
        sign=1<<(WIDTHS[fmt]-1)
        for rm in range(4):
            for az,bz,cz in [(0,0,0),(sign,0,sign),(sign,0,0),(0,sign,sign)]:
                t.add('signed_zero',[az],[bz],a_fmt=fmt,c_fmt=fmt,d_fmt=fmt,c=cz,rounding=rm)
    for rm in range(4):
        t.add('f64_borrow_entire_ram',[one(F64),0x8000000000000001],[one(F64),1],a_fmt=F64,c_fmt=F64,d_fmt=F64,rounding=rm)
        t.add('f64_huge_product_cancellation',[0x7fefffffffffffff,0xffefffffffffffff],[0x7fefffffffffffff]*2,a_fmt=F64,c_fmt=F64,d_fmt=F64,c=0x4008000000000000,rounding=rm)
        t.add('f64_negative_tiny',[0x8000000000000001],[1],a_fmt=F64,c_fmt=F64,d_fmt=F64,rounding=rm)
        t.add('bf16_tie_from_c',[0],[0],a_fmt=F32,c_fmt=F32,d_fmt=BF16,c=0x3f808000,rounding=rm)
        t.add('overflow_positive',[0x7bff],[0x7bff],a_fmt=F16,c_fmt=F16,d_fmt=F16,rounding=rm)
        t.add('overflow_negative',[0xfbff],[0x7bff],a_fmt=F16,c_fmt=F16,d_fmt=F16,rounding=rm)
    for a,b,c in [(0x7c00,0,0),(0xfc00,one(F16),0x7f800000),(0x7e01,0,0),(0x7c00,one(F16),0)]:
        t.add('fp16_special',[a],[b],c=c)
    for sa_fmt in [UE8M0,UE4M3,UE5M3]:
        for block in [0,1]:
            for k in [1,15,16,17,31,32,33,64]:
                length=16 if block==0 else 32; oa=3; ob=7
                av=[1+(i%7) for i in range(k)];bv=[9+(i%7) for i in range(k)]
                unity={UE8M0:127,UE4M3:56,UE5M3:120}[sa_fmt]
                sa=[unity+((oa+i)//length)%3 for i in range(k)]
                sb=[unity-((ob+i)//length)%3 for i in range(k)]
                t.add('scaled_fp4_boundaries',av,bv,a_fmt=E2M1,block_scale_en=1,block_size=block,
                      a_scale_fmt=sa_fmt,b_scale_fmt=sa_fmt,a_block_offset=oa,b_block_offset=ob,sa=sa,sb=sb)
    for raw in [0,1,0x78,0x7e,0x7f,0x80]:
        t.add('ue4_scale_codes',[7],[7],a_fmt=E2M1,block_scale_en=1,block_size=0,
              a_scale_fmt=UE4M3,b_scale_fmt=UE4M3,sa=[raw],sb=[56])
    for raw in [0,1,0xf8,0xfe,0xff]:
        t.add('ue5_scale_codes',[7],[7],a_fmt=E2M1,block_scale_en=1,block_size=1,
              a_scale_fmt=UE5M3,b_scale_fmt=UE5M3,sa=[raw],sb=[120])
    for rm in range(4):
        t.add('ue8_smallest_scaled',[1],[1],a_fmt=E5M2,block_scale_en=1,
              a_scale_fmt=UE8M0,b_scale_fmt=UE8M0,sa=[0],sb=[0],rounding=rm)
    for f in [S8,U8,S4,U4,TI16,B1]:
        vals=[0,1,(1<<WIDTHS[f])-1]
        if f==TI16: vals=[2047,(-2047)&65535,1]
        t.add('integer_'+NAMES[f],vals,vals,a_fmt=f,c_fmt=S32,d_fmt=S32,c=0xfffffffb,ti16_decoded=int(f==TI16))
    for sat in [0,1]:
        t.add('s32_overflow_positive',[255]*7,[255]*7,a_fmt=U8,c_fmt=S32,d_fmt=S32,c=0x7fffffff,int_sat=sat)
        t.add('s32_overflow_negative',[128]*7,[127]*7,a_fmt=S8,c_fmt=S32,d_fmt=S32,c=0x80000000,int_sat=sat)
    t.add('binary_xor',[0,1,0,1],[1,1,0,0],a_fmt=B1,c_fmt=S32,d_fmt=S32,c=3,binary_xor=1)
    t.add('c_scale_shift',[one(F16)],[one(F16)],c=one(F32),c_scale_shift=3)
    for raw in [2048,0xf800,0x8000]:
        t.add('ti16_out_of_range',[raw],[1],a_fmt=TI16,c_fmt=S32,d_fmt=S32,ti16_decoded=1)
    t.add('ti16_raw_unsupported',[0],[0],a_fmt=TI16,c_fmt=S32,d_fmt=S32,expect=(UNSUPPORTED,0))
    t.add('tf32_bad_low_bits',[0x3f800001],[one(TF32)],a_fmt=TF32)
    t.add('zero_k',[],[],expect=(LENGTH,0))
    t.add('unknown_profile',[0],[0],profile=1,expect=(UNSUPPORTED,0))
    t.add('scale_illegal_fp16',[0],[0],block_scale_en=1,a_scale_fmt=UE8M0,b_scale_fmt=UE8M0,expect=(BAD_CFG,0))
    t.add('scale_mismatch',[1],[1],a_fmt=E2M1,block_scale_en=1,a_scale_fmt=UE4M3,b_scale_fmt=UE5M3,expect=(BAD_CFG,0))
    t.add('scale_block16_illegal_e5m2',[1],[1],a_fmt=E5M2,block_scale_en=1,block_size=0,a_scale_fmt=UE8M0,b_scale_fmt=UE8M0,expect=(BAD_CFG,0))
    t.add('ti16_sat_illegal',[1],[1],a_fmt=TI16,c_fmt=S32,d_fmt=S32,ti16_decoded=1,int_sat=1,expect=(BAD_CFG,0))

def randomized(t, seed, count):
    rng=random.Random(seed)
    for i in range(count):
        fa=rng.choice(list(SPECS));fb=rng.choice(list(SPECS));fc=rng.choice([F16,BF16,F32,F64]);fd=rng.choice([F16,BF16,F32,F64]);k=rng.randint(1,9)
        def raw(f):
            v=rng.getrandbits(WIDTHS[f]);return v&~8191 if f==TF32 else v
        t.add('random_float_'+str(i),[raw(fa) for _ in range(k)],[raw(fb) for _ in range(k)],a_fmt=fa,b_fmt=fb,c_fmt=fc,d_fmt=fd,c=raw(fc),rounding=rng.randrange(4))
    for i in range(count):
        fa=rng.choice([S8,U8,S4,U4,TI16,B1]);fb=rng.choice([S8,U8]) if fa in [S8,U8] else rng.choice([S4,U4]) if fa in [S4,U4] else fa;k=rng.randint(1,65)
        def iraw(f): return rng.randint(-2047,2047)&65535 if f==TI16 else rng.getrandbits(WIDTHS[f])
        t.add('random_integer_'+str(i),[iraw(fa) for _ in range(k)],[iraw(fb) for _ in range(k)],a_fmt=fa,b_fmt=fb,c_fmt=S32,d_fmt=S32,c=rng.getrandbits(32),ti16_decoded=int(fa==TI16),int_sat=rng.randrange(2) if fa not in [TI16,B1] else 0,binary_xor=rng.randrange(2) if fa==B1 else 0)
    for i in range(count//2):
        sf=rng.choice([UE8M0,UE4M3,UE5M3]); block=rng.randrange(2);length=16 if block==0 else 32;k=rng.randint(1,70);oa=rng.randrange(length);ob=rng.randrange(length)
        fa=fb=E2M1
        if sf==UE8M0 and block==1: fa=rng.choice([E4M3,E5M2,E2M3,E3M2,E2M1]);fb=rng.choice([E4M3,E5M2,E2M3,E3M2,E2M1])
        sa_codes=[rng.randrange(128 if sf==UE4M3 else 256) for _ in range((oa+k+length-1)//length)]
        sb_codes=[rng.randrange(128 if sf==UE4M3 else 256) for _ in range((ob+k+length-1)//length)]
        t.add('random_scaled_'+str(i),[rng.getrandbits(WIDTHS[fa]) for _ in range(k)],[rng.getrandbits(WIDTHS[fb]) for _ in range(k)],a_fmt=fa,b_fmt=fb,c=rng.getrandbits(32),block_scale_en=1,block_size=block,a_scale_fmt=sf,b_scale_fmt=sf,a_block_offset=oa,b_block_offset=ob,sa=[sa_codes[(oa+j)//length] for j in range(k)],sb=[sb_codes[(ob+j)//length] for j in range(k)],rounding=rng.randrange(4))

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--out',type=Path,required=True);parser.add_argument('--suite',choices=['smoke','random','exhaustive'],default='smoke');parser.add_argument('--seed',type=int,default=1);parser.add_argument('--count',type=int,default=200);parser.add_argument('--no-fp64',action='store_true');args=parser.parse_args()
    t=Builder(args.no_fp64);directed(t)
    if args.suite in ['random','exhaustive']: randomized(t,args.seed,args.count)
    if args.suite=='exhaustive':
        for f in [E2M1,E2M3,E3M2]:
            for a in range(1<<WIDTHS[f]):
                for b in range(1<<WIDTHS[f]): t.add('exhaustive_'+NAMES[f],[a],[b],a_fmt=f)
        k=65535;t.add('maximum_k_integer',[255]*k,[255]*k,a_fmt=U8,c_fmt=S32,d_fmt=S32,c=0x7fffffff)
    args.out.parent.mkdir(parents=True,exist_ok=True)
    with args.out.open('w') as out:
        for case in t.cases:
            out.write(f"{pack_cfg(case['cfg']):016x} {case['c']:016x} {len(case['pairs'])} {case['status']} {case['data']:016x}\n")
            for a,b,sa,sb in case['pairs']: out.write(f'{a:016x} {b:016x} {sa:02x} {sb:02x}\n')
    manifest={'suite':args.suite,'seed':args.seed,'cases':len(t.cases),'oracle':'fractions.Fraction + integer quotient/remainder rounding; no DUT algorithms','no_fp64':args.no_fp64,'names':[c['name'] for c in t.cases]}
    args.out.with_suffix('.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(f"Generated {len(t.cases)} independently evaluated cases: {args.out}")

if __name__=='__main__': main()
