#!/usr/bin/env python3
"""Generate project-proposed MALU figures; no RTL or NVIDIA layout claims."""
from pathlib import Path
import os
os.environ.setdefault("MPLCONFIGDIR", "/tmp/malu-matplotlib")
os.environ.setdefault("XDG_CACHE_HOME", "/tmp/malu-fontcache")
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch
from matplotlib.font_manager import FontProperties

OUT = Path(__file__).resolve().parent
OUT.mkdir(parents=True, exist_ok=True)
FONT = "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc"
BOLD = "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc"
FP = FontProperties(fname=FONT)
FB = FontProperties(fname=BOLD)
NAVY = "#173553"
TEAL = "#087F8C"
ORANGE = "#D98432"
INK = "#20364B"
MUTED = "#52687B"
PALE = "#F0F5F9"
TINT = "#E8F5F4"
WARM = "#FFF3E7"
GRID = "#CBD7E1"
BOX_TEXTS = []

plt.rcParams.update({"svg.fonttype": "path", "axes.unicode_minus": False})

def txt(ax, x, y, text, size=13.5, color=INK, bold=False, ha="center", va="center", **kw):
    return ax.text(x, y, text, fontsize=max(size,13.5), color=color,
                   fontproperties=FB if bold else FP, ha=ha, va=va,
                   linespacing=1.25, **kw)

def box(ax, x, y, w, h, text, face=PALE, edge=NAVY, size=13,
        bold=False, lw=1.6, radius=1.0, color=INK):
    p = FancyBboxPatch((x,y), w,h,
        boxstyle=f"round,pad=0.0,rounding_size={radius}",
        facecolor=face, edgecolor=edge, linewidth=lw)
    ax.add_patch(p)
    t = txt(ax, x+w/2, y+h/2, text, size=size, color=color, bold=bold)
    BOX_TEXTS.append((ax, t, (x+.65,y+.55,w-1.3,h-1.1), size))
    return p

def arrow(ax, points, color=TEAL, dashed=False, lw=1.8, end=True):
    for a,b in zip(points[:-2], points[1:-1]):
        ax.plot([a[0],b[0]],[a[1],b[1]], color=color, linewidth=lw,
                linestyle=(0,(4,3)) if dashed else "-", zorder=1)
    if len(points)>1:
        p = FancyArrowPatch(points[-2], points[-1],
            arrowstyle="-|>" if end else "-", mutation_scale=14,
            linewidth=lw, color=color,
            linestyle=(0,(4,3)) if dashed else "-", zorder=1)
        ax.add_patch(p)

def canvas(number, title, subtitle):
    fig,ax=plt.subplots(figsize=(10,5.5),dpi=240)
    fig.patch.set_facecolor("white")
    ax.set(xlim=(0,120), ylim=(0,82))
    ax.set_axis_off()
    fig.subplots_adjust(left=.025,right=.975,bottom=.025,top=.98)
    txt(ax,2,79.2,f"{number:02d}  {title}",size=20,bold=True,ha="left",color=NAVY)
    txt(ax,2,75.0,subtitle,size=12.3,ha="left",color=MUTED)
    ax.plot([2,118],[72.9,72.9],color=GRID,lw=1)
    txt(ax,2,2.3,"项目拟议架构 · 非 NVIDIA 实图 · 不代表已确认的 NVIDIA 微架构",size=10.8,ha="left",color=MUTED)
    return fig,ax

def save(fig, stem):
    fig.canvas.draw()
    renderer = fig.canvas.get_renderer()
    overflows=[]
    for ax,t,(x,y,w,h),original in BOX_TEXTS:
        if ax.figure is not fig:
            continue
        lo=ax.transData.transform((x,y)); hi=ax.transData.transform((x+w,y+h))
        for _ in range(30):
            bounds=t.get_window_extent(renderer=renderer)
            if bounds.width <= hi[0]-lo[0] and bounds.height <= hi[1]-lo[1]:
                break
            t.set_fontsize(t.get_fontsize()-.25)
            fig.canvas.draw()
        if t.get_fontsize() < 13.5:
            t.set_fontsize(13.5)
            fig.canvas.draw()
            bounds=t.get_window_extent(renderer=renderer)
            overflows.append((t.get_text(),round(bounds.width/(hi[0]-lo[0]),2),round(bounds.height/(hi[1]-lo[1]),2)))
    if overflows:
        raise ValueError(f"Text too dense in {stem}: {overflows}")
    fig.savefig(OUT/f"{stem}.png",dpi=240,facecolor="white")
    fig.savefig(OUT/f"{stem}.svg",facecolor="white")
    plt.close(fig)

def fig1():
    fig,ax=canvas(1,"纯向量 DOT 数据通路","单输出 / 事务；格式、Scale 与块配置独立，由合法 profile 约束。")
    box(ax,2,61.5,33,9.3,"数据格式\na/b/c/d_fmt",size=13.5)
    box(ax,39.5,61.5,38,9.3,"缩放数据 / 格式\na/b_scale_data · a/b_scale_fmt",face=TINT,edge=TEAL,size=13.5)
    box(ax,82,61.5,36,9.3,"块配置（事务间切换）\nenable · BLOCK16/32 · offset",face=WARM,edge=ORANGE,size=13.5)
    box(ax,2,28,13,15,"A / B\n原始载荷\n握手输入",size=13.5)
    box(ax,19,28,16,15,"解包 / 分类\n合法性检查\n数值域提取",size=13.5)
    box(ax,40,35.5,17,10,"浮点乘积\n精度按 profile",face=TINT,edge=TEAL,size=13.5)
    box(ax,40,20.5,17,10,"整型乘积\nA/B 独立符号",face=TINT,edge=TEAL,size=13.5)
    box(ax,40,49.2,17,8.5,"Scale 解码\nA/B 独立缓存",face=WARM,edge=ORANGE,size=13.5)
    box(ax,62,28,15,15,"乘积归约\n部分和生成\n按 profile",size=13.5)
    box(ax,82,28,16,15,"累加上下文\nC 纳入一次\n跨拍保留",face=TINT,edge=TEAL,size=13.5)
    box(ax,103,28,15,15,"结果处理\nround/pack\n按 profile",size=13.5)
    box(ax,82,8.5,16,14.1,"C 正式输入\nc_fmt\n接收时锁存",face=WARM,edge=ORANGE,size=13.5)
    box(ax,103,8.5,15,14.1,"D + tag\nd_fmt\n反压时保持",face=TINT,edge=TEAL,size=13.5)
    arrow(ax,[(15,35.5),(19,35.5)])
    arrow(ax,[(35,35.5),(37,35.5),(37,40.5),(40,40.5)])
    arrow(ax,[(35,35.5),(37,35.5),(37,25.5),(40,25.5)])
    arrow(ax,[(57,40.5),(59.5,40.5),(59.5,35.5),(62,35.5)])
    arrow(ax,[(57,25.5),(59.5,25.5),(59.5,35.5),(62,35.5)])
    arrow(ax,[(77,35.5),(82,35.5)])
    arrow(ax,[(98,35.5),(103,35.5)])
    arrow(ax,[(90,22.6),(90,28)],color=ORANGE)
    arrow(ax,[(110.5,28),(110.5,22.6)])
    arrow(ax,[(27,61.5),(27,43)],dashed=True,color=NAVY)
    arrow(ax,[(48.5,61.5),(48.5,57.7)],dashed=True,color=ORANGE)
    arrow(ax,[(48.5,49.2),(48.5,45.5)],color=ORANGE)
    arrow(ax,[(57,53.5),(58.8,53.5),(58.8,30.9),(52.5,30.9),(52.5,30.5)],color=ORANGE)
    arrow(ax,[(82,65.3),(79.7,65.3),(79.7,53.5),(57,53.5)],dashed=True,color=ORANGE)
    box(ax,2,8.5,75,9.7,"仅向量 DOT；不含标量 FMA / SFU / 通用 ALU\n内部精度、归约及舍入按 profile；不假定全 DOT 只末次舍入。",face="white",edge=GRID,size=13.5,lw=1.1)
    save(fig,"01_malu_dot_datapath")

def fig2():
    fig,ax=canvas(2,"BLOCK16 / BLOCK32 分组示例","K = 64 元素；A/B offset = 0；本例两侧块长相同，配置仍独立。")
    def panel(y, length):
        groups=64//length
        txt(ax,2,y+22.5,f"BLOCK{length}",size=16.5,bold=True,ha="left",color=NAVY)
        txt(ax,118,y+22.5,f"{groups} 组 × {length} 元素；A/B 各 {groups} 个 scale",size=12.7,ha="right",color=MUTED)
        start=13; total=105; gap=1.0
        width=(total-gap*(groups-1))/groups
        txt(ax,4,y+13,"A",size=17,bold=True,color=TEAL)
        txt(ax,4,y+2,"B",size=17,bold=True,color=ORANGE)
        for j in range(groups):
            x=start+j*(width+gap)
            k0=j*length; k1=(j+1)*length-1
            box(ax,x,y+9,width,8.0,f"k = {k0}…{k1}\n× S_A[{j}]",face=TINT,edge=TEAL,size=13.8)
            box(ax,x,y-2,width,8.0,f"k = {k0}…{k1}\n× S_B[{j}]",face=WARM,edge=ORANGE,size=13.8)
    panel(46,16)
    panel(14,32)
    ax.plot([2,118],[40.2,40.2],color=GRID,lw=1)
    txt(ax,2,7.7,"A/B Scale 独立，格式不由数据格式推导；16/32 为元素数，不代表周期或物理 lane。",size=13.5,ha="left",color=MUTED)
    save(fig,"02_block_scale_groups")

def fig3():
    fig,ax=canvas(3,"事务、分拍与反压约束","descriptor + C → operand beats → response；阶段示意，列宽不代表时钟周期。")
    xs=[23+i*11.9 for i in range(8)]
    headers=["请求接收","首数据拍","块内续拍","输入停顿","新块首拍","后续/末拍","输出停顿","结果消费"]
    for x,h in zip(xs,headers):
        txt(ax,x+5.4,68,h,size=11.7,bold=True,color=NAVY)
    rows=[(54,"descriptor\n+ C"),(40,"A / B\n数据拍"),(26,"A / B\nscale"),(12,"response\nD + tag")]
    for y,label in rows:
        txt(ax,3,y+5.5,label,size=13,bold=True,ha="left",color=NAVY)
        for x in xs:
            box(ax,x,y,10.8,12.5,"—",face="white",edge=GRID,size=13.5,lw=1)
    def cell(col,row,text,face=PALE,edge=NAVY,size=11.7):
        box(ax,xs[col],rows[row][0],10.8,12.5,text,face=face,edge=edge,size=13.5,lw=1.4)
    cell(0,0,"握手接收\n锁存配置\nC 一次",face=WARM,edge=ORANGE)
    cell(1,1,"接受 n0\nk += n0",face=TINT,edge=TEAL)
    cell(2,1,"接受 n1\nk += n1",face=TINT,edge=TEAL)
    cell(3,1,"valid=1\nready=0\nk 不变",face=WARM,edge=ORANGE)
    cell(4,1,"接受 n2\n不跨块",face=TINT,edge=TEAL)
    cell(5,1,"… last\n累计 K",face=TINT,edge=TEAL)
    cell(1,2,"首块\nScale\nA/B独立",face=WARM,edge=ORANGE)
    cell(2,2,"块内缓存\n复用",face=PALE,edge=TEAL)
    cell(3,2,"配对状态\n保持",face=WARM,edge=ORANGE)
    cell(4,2,"进入新块\n按需更新",face=WARM,edge=ORANGE)
    cell(5,2,"按块续用\n或更新",face=PALE,edge=TEAL)
    cell(6,3,"v1 / r0\nD/tag\n保持",face=WARM,edge=ORANGE)
    cell(7,3,"valid=1\nready=1\n结果消费",face=TINT,edge=TEAL)
    arrow(ax,[(23,9.5),(117,9.5)],lw=1.3)
    txt(ax,2,5.6,"单上下文：结果消费后接收下一事务；每拍不跨 A/B 任一 Scale 块边界。",size=13.5,ha="left",color=MUTED)
    save(fig,"03_transaction_and_backpressure")

def fig4():
    fig,ax=canvas(4,"资源、有效吞吐与带宽关系","P_f 为有效平均 products/cycle（含利用损失），对应正文 P_eff。")
    box(ax,2,51,35.5,19,"标称比例与规模\nRubin dense 比率见图 5\nP_peak,f = S × r_f\n规模 S / packing 后续确定",face=PALE,size=13.5)
    box(ax,42,51,35.5,19,"乘积与归约资源\nP_peak = L_f / II_f\nP_f = P_eff = η × P_peak\n乘法 / 归约 / 累加共同约束",face=TINT,edge=TEAL,size=13.5)
    box(ax,82,51,36,19,"端口与持续吞吐\nA/B + C + Scale 输入、D 输出\n尾拍 / 块边界 / 反压损失\n按定义计入 II 或 η 一次",face=WARM,edge=ORANGE,size=13.5)
    arrow(ax,[(37.5,60),(42,60)])
    arrow(ax,[(77.5,60),(82,60)])
    box(ax,2,37,116,10,"固定 K：DOT/cycle = P_f / K      MAC ops/cycle = 2P_f      ops/s = 2F × P_f\nD = C + Σ(A×B)；F 为目标频率。Scale 操作不额外充作 Tensor FLOPs。",face="white",edge=GRID,size=13.5,lw=1.2)
    box(ax,2,11.5,72,22,"每 DOT 最低位数（不重复传送 Scale）\nB_in = K(s_A+s_B)+s_C+N_A s_SA+N_B s_SB\n启用：N_X = 1+floor((o_X+K−1)/L_X)\n禁用：N_X=0；K>0；B_out=s_D\n平均位/周期 = (P_f/K) × 每 DOT 位数",face=PALE,size=13.5)
    box(ax,79,11.5,39,22,"64-bit A/B 各自端口示例\nP_f × s_A ≤ 64；P_f × s_B ≤ 64\ns_A / s_B 为传输 slot 位宽\n共享端口须合并计算带宽",face=TINT,edge=TEAL,size=13.5)
    txt(ax,2,7.2,"dense / sparse 分开；实际非零产品数与 dense-equivalent 算力不可混用。",size=13.5,ha="left",color=MUTED)
    save(fig,"04_throughput_and_bandwidth")

if __name__ == "__main__":
    for fn in (fig1,fig2,fig3,fig4):
        fn()
    print("Generated four PNG + SVG figure pairs.")
