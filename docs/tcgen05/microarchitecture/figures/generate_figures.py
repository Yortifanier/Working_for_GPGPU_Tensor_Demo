#!/usr/bin/env python3
"""Draw the project's proposed Tensor microarchitecture, not an NVIDIA design."""
from pathlib import Path
import argparse
import os
import subprocess

os.environ.setdefault("MPLCONFIGDIR", "/tmp/tcgen05-micro-mpl")
os.environ.setdefault("XDG_CACHE_HOME", "/tmp/tcgen05-micro-fontcache")
Path(os.environ["MPLCONFIGDIR"]).mkdir(parents=True,exist_ok=True)
Path(os.environ["XDG_CACHE_HOME"]).mkdir(parents=True,exist_ok=True)
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.font_manager import FontProperties
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch

ROOT=Path(__file__).resolve().parent
FONT_FILE=subprocess.check_output(["fc-match","-f","%{file}","Noto Sans CJK SC"],text=True).strip()
FONT=FontProperties(fname=FONT_FILE)
NAVY,TEAL,ORANGE="#173553","#087F8C","#CF7B2A"
INK,GRAY,GRID="#20364B","#52687B","#CBD7E1"
PALE,MINT,WARM="#F0F5F9","#E8F5F4","#FFF3E7"
plt.rcParams.update({"svg.fonttype":"path","axes.unicode_minus":False})
CHECKS=[]


def text(ax,x,y,label,size=13.5,color=INK,bold=False,ha="center",va="center"):
    return ax.text(x,y,label,fontproperties=FONT,fontsize=size,color=color,
                   fontweight="bold" if bold else "normal",ha=ha,va=va,linespacing=1.24)


def box(ax,x,y,w,h,label,face=PALE,edge=NAVY,size=13.5,dashed=False):
    ax.add_patch(FancyBboxPatch((x,y),w,h,boxstyle="round,pad=0,rounding_size=.9",
        facecolor=face,edgecolor=edge,linewidth=1.5,
        linestyle=(0,(4,3)) if dashed else "-",zorder=2))
    t=text(ax,x+w/2,y+h/2,label,size=size)
    CHECKS.append((ax,t,(x+.6,y+.45,w-1.2,h-.9)))


def wire(ax,points,color=TEAL,dashed=False,lw=1.7):
    for a,b in zip(points[:-2],points[1:-1]):
        ax.plot([a[0],b[0]],[a[1],b[1]],color=color,linewidth=lw,
                linestyle=(0,(4,3)) if dashed else "-",zorder=1)
    ax.add_patch(FancyArrowPatch(points[-2],points[-1],arrowstyle="-|>",
        mutation_scale=13,color=color,linewidth=lw,zorder=1,
        linestyle=(0,(4,3)) if dashed else "-"))


def canvas(number,title,subtitle):
    fig,ax=plt.subplots(figsize=(10,6.7),dpi=240)
    fig.patch.set_facecolor("white")
    fig.subplots_adjust(left=.025,right=.975,bottom=.025,top=.98)
    ax.set(xlim=(0,120),ylim=(0,84));ax.axis("off")
    text(ax,2,80,f"{number:02d}  {title}",size=19,bold=True,ha="left",color=NAVY)
    text(ax,2,75.8,subtitle,size=13.5,ha="left",color=GRAY)
    ax.plot([2,118],[73.2,73.2],color=GRID,lw=1)
    text(ax,2,2.6,"项目拟议微架构 · 非 NVIDIA 结构图 · 数字为项目设计选择",ha="left",color=GRAY)
    return fig,ax


def save(fig,name):
    fig.canvas.draw();renderer=fig.canvas.get_renderer();overflow=[]
    for ax,t,(x,y,w,h) in CHECKS:
        if ax.figure is not fig: continue
        a=ax.transData.transform((x,y));b=ax.transData.transform((x+w,y+h))
        bounds=t.get_window_extent(renderer=renderer)
        if bounds.width>b[0]-a[0] or bounds.height>b[1]-a[1]:
            overflow.append((t.get_text(),round(bounds.width/(b[0]-a[0]),2),round(bounds.height/(b[1]-a[1]),2)))
    if overflow: raise RuntimeError(f"Text does not fit {name}: {overflow}")
    fig.savefig(ROOT/(name+".png"),dpi=240,facecolor="white")
    svg = ROOT/(name+".svg")
    fig.savefig(svg,facecolor="white")
    svg.write_text('\n'.join(line.rstrip() for line in svg.read_text().splitlines())+'\n')
    plt.close(fig)


def subsystem():
    fig,ax=canvas(1,"Tensor 子系统组织","共享 SMEM 属 core 侧系统模块；Tensor 经 operand buffers 接入。")
    box(ax,2,60,17,11,"外部 core\nwarp / issuer\ncmd",face="white",edge=GRAY)
    box(ax,23,62,56,9,"normal / escape 按类别进入\n联合合法性、资源租约与 tile 计划分工",face="white",edge=GRID)
    box(ax,83,58,35,13,"共享 SMEM 子系统\n详见 SMEM 图；core 侧\n外部 TMA",face="white",edge=GRAY)
    boxes=[(2,17,"命令入口\nnormalCQ 24\nescapeCQ 8"),
           (23,14,"decode\nlegalizer"),(41,18,"OpTable 64\nregion\nscoreboard"),
           (63,16,"8 tile ctx\nlayout\nplanner"),(83,16,"operand\nbuffers"),
           (103,15,"MALU\nREF / PERF")]
    for x,w,label in boxes: box(ax,x,39,w,16,label,face=MINT if x==103 else PALE)
    for (x,w,_),(nx,_,_) in zip(boxes,boxes[1:]): wire(ax,[(x+w,47),(nx,47)])
    wire(ax,[(10.5,60),(10.5,55)])
    wire(ax,[(100.5,58),(100.5,57),(91,57),(91,55)])
    box(ax,103,18,15,12,"WBQ\nD writeback")
    box(ax,83,18,16,12,"TMEM\nendpoint(s)")
    box(ax,62,18,17,12,"completion\ncommit / wait")
    box(ax,27,18,31,12,"allocator / collector\n资源与复用状态")
    box(ax,2,18,17,12,"外部 peer\nendpoint 协同",face="white",edge=GRAY)
    box(ax,62,6.7,17,8.3,"外部 barrier\nnotify / ack",face="white",edge=GRAY)
    wire(ax,[(110.5,39),(110.5,30)])
    wire(ax,[(103,24),(99,24)])
    wire(ax,[(83,24),(79,24)],dashed=True)
    wire(ax,[(70.5,18),(70.5,15)],color=ORANGE)
    wire(ax,[(19,24),(27,24)],color=GRAY,dashed=True)
    wire(ax,[(49,30),(49,39)],dashed=True)
    save(fig,"01_tensor_subsystem")


def dispatch():
    fig,ax=canvas(2,"前端发射与阻塞分流","S0–S5 是可停顿的逻辑阶段；不宣称每条命令固定 6 cycles。")
    stages=[(2,18,"S0  接收\nnormalCQ 24\nescapeCQ 8"),
            (25,18,"S1  capture\nissuer / 描述符\n上下文锁存"),
            (48,20,"S2  legalize\nkind / type\ntarget / shape"),
            (73,20,"S3  atomic lease\n区域 / endpoint\n全取或不取"),
            (98,20,"S4  plan\n8 tile ctx\nlayout / tiles")]
    for x,w,label in stages: box(ax,x,49,w,18,label)
    for (x,w,_),(nx,_,_) in zip(stages,stages[1:]):wire(ax,[(x+w,58),(nx,58)])
    box(ax,98,27,20,13,"S5  dispatch\noperand / MALU",face=MINT,edge=TEAL)
    wire(ax,[(108,49),(108,40)])
    box(ax,48,27,20,13,"alloc waitQ 8\n阻塞 alloc 分流",face=WARM,edge=ORANGE)
    wire(ax,[(83,49),(83,33.5),(68,33.5)],color=ORANGE)
    wire(ax,[(58,40),(58,44),(75,44),(75,49)],dashed=True,color=ORANGE)
    text(ax,30,35,"资源满足后重试",color=GRAY)
    box(ax,2,8,91,14,"独立 escape / completion / release 进度路径\n完成确认、commit 与释放不被等待 alloc 的队头阻塞",face=WARM,edge=ORANGE)
    wire(ax,[(10.5,22),(10.5,49)],color=ORANGE,dashed=True)
    text(ax,108,17,"dispatch 也可停顿",color=GRAY)
    save(fig,"02_dispatch_and_issue")


def operand():
    fig,ax=canvas(3,"TMEM endpoint 与操作数预算","容量按 endpoint 计量；CTA pair 获得的是事务式联合授予。")
    box(ax,2,43,52,27,"每 endpoint：32 banks × 32-bit\n每 bank 1R1W\nbank = lane[4:0]\nrow = 4 × col + lane[6:5]\nMAX_COLS = 576 → 288 KiB",face=PALE)
    box(ax,60,43,58,27,"每 cycle：128 B 读 + 128 B 写\nfull column：128 lanes × 4 B = 512 B\n每个方向传完一列需 4 cycles\n端口预算不等于单指令固定延迟",face=MINT,edge=TEAL)
    text(ax,2,38.2,"操作数暂存与复用容量（独立于上方 TMEM 容量）",ha="left",bold=True,color=NAVY)
    box(ax,2,20,34,14,"A snapshot\n2 × 16 KiB\nSMEM / TMEM A")
    box(ax,43,20,34,14,"B collector\n4 × 8 KiB\nSMEM B")
    box(ax,84,20,34,14,"scale / metadata\n8 KiB\nTMEM 辅助数据")
    box(ax,2,6.5,116,11.5,"CTA pair：2 endpoint 事务式分配，全部成功才授予\nallocation records：18 / endpoint，pair 共 36\n不为每个 CTA 复制一份 288 KiB 容量",face=WARM,edge=ORANGE)
    save(fig,"03_operand_and_tmem")


def completion():
    fig,ax=canvas(6,"异步完成、通知与退休","normal / ARead 按 active issuer 隔离；ld/st 另有 per-warp 完成域。")
    box(ax,2,48,32,19,"每个 active issuer\nnormal MCS seq\nfull-done prefix")
    box(ax,2,24,32,19,"SMEM-A MMA A-read\nARead seq / prefix\n独立 A 读取跟踪",face=MINT,edge=TEAL)
    box(ax,40,36,23,17,"commit 快照\nnormal 或 ARead\n按类别选择")
    box(ax,69,36,20,17,"commit wait\n8 entries")
    box(ax,95,36,23,17,"eventQ 16\nbarrier notify\n等待 ack")
    box(ax,95,61,23,9,"外部 barrier\n确认 ack",face="white",edge=GRAY)
    wire(ax,[(34,57.5),(37,57.5),(37,44.5),(40,44.5)])
    wire(ax,[(34,33.5),(37,33.5),(37,44.5),(40,44.5)])
    wire(ax,[(63,44.5),(69,44.5)])
    wire(ax,[(89,44.5),(95,44.5)])
    wire(ax,[(102,53),(102,61)])
    wire(ax,[(113,61),(113,53)],color=ORANGE)
    box(ax,40,8,78,19,"ARead 可早通知，不提前退休 token / lease\nD 全部写回 → full-done → 允许退休\nld/st：per-warp seq + wait，不混入 MCS",face=WARM,edge=ORANGE)
    save(fig,"04_async_tracking")


def adapter():
    fig,ax=canvas(5,"REF 适配与 PERF 拟议资源","两种实现状态分区；PERF 数字是入口预算，尚非端到端吞吐保证。")
    box(ax,2,66,116,5,"归一化 dot / C / format / scale 输入；按实现模式与合法格式选择路径",face="white",edge=GRID)
    box(ax,2,28,28,34,"REF：现有 SV exact 核\n单个共享 mul\nFP64 on：53×53\nFP64 off：24×24\nRAM on：132 ×32 bit\nRAM off：20 ×32 bit\nPROJECT_EXACT",face=MINT,edge=TEAL)
    # PERF outline contains proposed resources; inner boxes remain readable.
    ax.add_patch(FancyBboxPatch((36,28),82,34,boxstyle="round,pad=0,rounding_size=.9",
        facecolor="white",edgecolor=ORANGE,linewidth=1.6,linestyle=(0,(4,3)),zorder=0))
    text(ax,77,63.9,"PERF：拟议、未实现",size=14.5,bold=True,color=ORANGE)
    box(ax,40,45,36,14,"8 base groups\n每组 2 × 11×11；4 ctx\n宽 term：2 / 2 / 1\nF16 / BF16 / TF32",face=WARM,edge=ORANGE)
    box(ax,81,45,33,14,"6 boosters\n每组 1 raw brick\n每组 2 ctx",face=WARM,edge=ORANGE)
    box(ax,40,31,74,10,"FP8/6：80b local sum，LSB = −32\nFP4：signed9 q-prod → signed14 q-sum\n9 scale 后端：14b |R| × unsigned8 → 22b",face=WARM,edge=ORANGE)
    box(ax,2,11,28,14,"PERF 入口预算\nterms / cycle\nTF32 / F16 / FP8 / FP4\n8 / 16 / 70 / 140",face=PALE)
    box(ax,36,15,82,10,"640b exact CSA：44 ctx = 8×4 + 6×2\n3 × finalizer（目标 II=1）→ WBQ；尚未实现",face=WARM,edge=ORANGE)
    box(ax,36,5.5,82,7.5,"159 个 4×4 等价砖 = 8×18 + 6 + 9\nbase18：8raw+1coef+8scale+1spare；boost 另 9",face="white",edge=GRID)
    wire(ax,[(16,66),(16,62)])
    wire(ax,[(115.5,66),(115.5,62)],color=ORANGE)
    wire(ax,[(58,45),(58,43),(37.5,43),(37.5,25)],color=ORANGE)
    wire(ax,[(58,45),(58,41)],color=ORANGE)
    wire(ax,[(97.5,45),(97.5,41)],color=ORANGE)
    wire(ax,[(114,51),(116.5,51),(116.5,25)],color=ORANGE)
    wire(ax,[(77,31),(77,25)],color=ORANGE)
    save(fig,"05_malu_adapter")


def smem():
    fig,ax=canvas(4,"SMEM 共享存储子系统（core 侧）","独立于 TMEM；容量、端口与队列组织均为项目拟议选择。")
    box(ax,2,56,56,15,"256 KiB / endpoint（SMEM）\n64 banks ×32-bit ×1024 rows\np：owner 转译后物理 byte address\nbank=p[7:2]；row=p[17:8]",face=PALE)
    box(ax,62,56,56,15,"共享峰值：256 B 读 +256 B 写 / cycle\nTensor：2 ×128 B，非独占\nCTA launch 分配：8 owners",face=MINT,edge=TEAL)
    clients=[(2,"LSU"),(26,"TMA"),(50,"Tensor"),(74,"peer"),(98,"barrier")]
    for x,label in clients:
        box(ax,x,44,20,10,label+"\n独立 reqQ",face=WARM if label=="barrier" else PALE,
            edge=ORANGE if label=="barrier" else NAVY)
        wire(ax,[(x+10,44),(x+10,40)],color=ORANGE if label=="barrier" else TEAL)
    ax.plot([12,108],[40,40],color=TEAL,linewidth=1.7,zorder=1)
    wire(ax,[(19,40),(19,37)])
    box(ax,2,25,34,12,"AGU / fragment\nTensor swizzle 仅一次\nowner 转译 / 范围检查")
    box(ax,42,25,34,12,"per-bank arbiter\nRMW locks\n共享端口仲裁")
    box(ax,84,25,34,12,"64 physical banks\n每 bank 1R1W\n1024 ×32-bit rows",face=MINT,edge=TEAL)
    wire(ax,[(36,31),(42,31)])
    wire(ax,[(76,31),(84,31)])
    box(ax,2,7,34,14,"barrier / 已承诺返回\n独立 credit\n保留完成进度",face=WARM,edge=ORANGE)
    box(ax,42,7,34,14,"tagged return\nreassembly\n按 client/tag 返回")
    box(ax,84,7,34,14,"store visibility\ncollector invalidate\n或版本更新\n→ 发布 ack",face=WARM,edge=ORANGE)
    wire(ax,[(36,14),(39,14),(39,31),(42,31)],color=ORANGE,dashed=True)
    wire(ax,[(84,29),(80,29),(80,14),(76,14)])
    wire(ax,[(101,25),(101,21)],color=ORANGE)
    save(fig,"06_smem_subsystem")


if __name__=="__main__":
    drawings={"01_tensor_subsystem":subsystem,"02_dispatch_and_issue":dispatch,
              "03_operand_and_tmem":operand,"04_async_tracking":completion,
              "05_malu_adapter":adapter,"06_smem_subsystem":smem}
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only",nargs="+",choices=drawings)
    args=parser.parse_args()
    ROOT.mkdir(parents=True,exist_ok=True)
    selected=args.only or list(drawings)
    for name in selected: drawings[name]()
    print(f"Generated {len(selected)} microarchitecture PNG/SVG pairs (2400 × 1608).")
