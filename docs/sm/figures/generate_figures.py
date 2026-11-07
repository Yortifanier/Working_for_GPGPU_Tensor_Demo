#!/usr/bin/env python3
"""Draw the project's proposed SM architecture, not an NVIDIA chip design."""
from pathlib import Path
import argparse
import os
import subprocess

os.environ.setdefault("MPLCONFIGDIR", "/tmp/sm-architecture-mpl")
os.environ.setdefault("XDG_CACHE_HOME", "/tmp/sm-architecture-fontcache")
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
    text(ax,2,2.6,"项目 SM 拟议组织 · 非 NVIDIA 芯片结构图 · 物理参数为项目选择",ha="left",color=GRAY)
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


def overview():
    fig,ax=canvas(1,"SM 总体组织","SM-ARCH-S0：1 core =1 SM；每 SM 1 个逻辑 Tensor endpoint（项目选择）。")
    top=[(2,24,"CTA launch\n≤8 resident CTA\n资源全有全无"),(32,24,"≤64 resident warps\n32 threads / warp\nPC / mask / wait"),
         (62,24,"fetch / decode\n项目指令前端"),(92,26,"issue / scoreboard\n依赖与执行资格")]
    for x,w,label in top: box(ax,x,59,w,12,label)
    for (x,w,_),(nx,_,_) in zip(top,top[1:]): wire(ax,[(x+w,65),(nx,65)])
    box(ax,2,36,24,16,"线程 GPR / predicate\nRF 容量参数化\n分配与写回")
    box(ax,32,36,24,16,"operand collector\n按 tag / lane\n供给执行域")
    box(ax,62,36,24,16,"SIMT 执行域\nINT / FP / FMA\nSFU",face=MINT,edge=TEAL)
    box(ax,92,36,26,16,"Tensor 执行域\ntcgen05 控制\nMALU：仅 DOT",face=MINT,edge=TEAL)
    wire(ax,[(105,59),(105,55),(44,55),(44,52)])
    wire(ax,[(26,44),(32,44)])
    wire(ax,[(56,44),(62,44)])
    wire(ax,[(56,48),(59,48),(59,54),(105,54),(105,52)])
    box(ax,2,16,24,14,"LSU / AGU\ncoalesce / atomic\n访存与返回")
    box(ax,32,16,24,14,"L1 / TLB\nmiss / replay\n通向外部 L2")
    box(ax,62,16,24,14,"core 共享 SMEM\n256 KiB / SM\nTMA / barrier")
    box(ax,92,16,26,14,"Tensor TMEM\n最大 288 KiB / SM\nD 写回与读出")
    wire(ax,[(14,36),(14,30)])
    wire(ax,[(26,19),(32,19)])
    wire(ax,[(26,24),(29,24),(29,31),(74,31),(74,30)])
    wire(ax,[(105,36),(105,30)])
    wire(ax,[(74,36),(74,33),(14,33),(14,36)],color=ORANGE,dashed=True)
    box(ax,2,6,116,7,"warp 通信、texture/surface、Fabric、调试与运行时：独立服务接口、能力位与返回责任",face="white",edge=GRID)
    save(fig,"01_sm_overview")


def warp_control():
    fig,ax=canvas(2,"warp / CTA 调度与分歧控制","每 SM：≤64 warps、≤8 CTA、32 threads / warp；控制状态与完成责任分开。")
    stages=[(2,20,"CTA admission\n资源全有全无"),(27,20,"resident warp\n线程 PC / mask"),
            (52,20,"eligible 检查\n依赖 / 操作数"),(77,17,"scheduler\n选择与公平"),
            (99,19,"issue\n执行域接受")]
    for x,w,label in stages: box(ax,x,56,w,15,label)
    for (x,w,_),(nx,_,_) in zip(stages,stages[1:]): wire(ax,[(x+w,63.5),(nx,63.5)])
    box(ax,2,27,32,20,"分支 / predicate\n分歧与汇合状态\n更新 PC / mask",face=MINT,edge=TEAL)
    box(ax,44,27,32,20,"CTA barrier / yield\n等待原因独立记录\n参与集合按语义确定")
    box(ax,86,27,32,20,"执行 / 访存返回\nscoreboard 释放\nwakeup / retry",face=WARM,edge=ORANGE)
    wire(ax,[(108.5,56),(108.5,51),(18,51),(18,47)])
    wire(ax,[(18,47),(18,52),(37,52),(37,56)],dashed=True)
    wire(ax,[(108.5,56),(108.5,49),(60,49),(60,47)])
    wire(ax,[(102,47),(102,53),(62,53),(62,56)],color=ORANGE)
    box(ax,2,8,116,12,"CTA exit / trap / abort：停止新责任后 drain；在途返回、锁与 owner 引用归零后回收\nwarp 停顿不阻止独立完成、控制和返回通道前进",face=WARM,edge=ORANGE)
    save(fig,"02_warp_cta_control")


def register_execution():
    fig,ax=canvas(3,"统一寄存器与执行域","寄存器命名、物理 bank 和数值功能分开；Tensor 的矩阵 payload 另走存储接口。")
    box(ax,2,61,116,10,"指令携带 warp / lane mask / 源与目的类型；scoreboard 记录真实数据依赖和完成责任",face="white",edge=GRID)
    box(ax,2,44,30,13,"GPR / predicate\nper-thread CC 状态\nRF 容量参数化")
    box(ax,40,44,24,13,"operand collector\n读出 / bypass\n按身份保留")
    box(ax,72,44,20,13,"INT / logic\n比较 / 位操作",face=MINT,edge=TEAL)
    box(ax,98,44,20,13,"FP / FMA\n数值 profile",face=MINT,edge=TEAL)
    box(ax,72,26,20,13,"SFU\n专用函数域",face=MINT,edge=TEAL)
    box(ax,98,26,20,13,"LSU / atomic\n地址与数据",face=MINT,edge=TEAL)
    wire(ax,[(32,50.5),(40,50.5)])
    wire(ax,[(64,50.5),(72,50.5)])
    wire(ax,[(64,56.5),(67,56.5),(67,59.5),(96,59.5),(96,50.5),(98,50.5)])
    wire(ax,[(64,47),(68,47),(68,32.5),(72,32.5)])
    wire(ax,[(64,47),(68,47),(68,41.5),(108,41.5),(108,39)])
    box(ax,2,26,30,13,"writeback arbiter\ntag / lane / mask\n目的寄存器与异常")
    wire(ax,[(17,39),(17,44)],color=ORANGE)
    wire(ax,[(82,26),(82,23),(17,23),(17,26)],color=ORANGE,dashed=True)
    wire(ax,[(108,26),(108,23),(82,23)],color=ORANGE,dashed=True)
    wire(ax,[(92,50.5),(95,50.5),(95,23),(82,23)],color=ORANGE,dashed=True)
    wire(ax,[(118,50.5),(119.3,50.5),(119.3,23),(108,23)],color=ORANGE,dashed=True)
    box(ax,2,7,62,13,"Tensor 命令：GPR 提供描述符 / 标量控制\n矩阵 A/B/C/D payload 不等同普通寄存器 ALU 操作数")
    box(ax,72,7,46,13,"SMEM / TMEM → 点积 MALU → TMEM\ntcgen05.ld 的结果另经寄存器返回路径",face=WARM,edge=ORANGE)
    wire(ax,[(64,13.5),(72,13.5)],color=ORANGE)
    save(fig,"03_register_execution")


def memory_hierarchy():
    fig,ax=canvas(4,"L1 / SMEM / TMEM 与访存层次","SM-ARCH-S0 每 SM 1 个逻辑 Tensor endpoint；SMEM、TMEM 为独立物理池。")
    box(ax,2,59,30,12,"LSU\n地址空间与访问类型")
    box(ax,44,59,32,12,"Tensor / tcgen05\n受保护矩阵访问")
    box(ax,88,59,30,12,"TMA adapter\n分段传输 / 代理")
    box(ax,2,35,30,17,"L1 / TLB / missQ\nglobal / local 路径\n容量与端口另作预算")
    box(ax,42,35,36,17,"SMEM：256 KiB / SM\n64 banks ×32-bit\nLSU / TMA / Tensor / peer",face=MINT,edge=TEAL)
    box(ax,88,35,30,17,"TMEM：最大 288 KiB / SM\n1 逻辑 endpoint / SM\n32 banks ×32-bit\nTensor lane / column",face=MINT,edge=TEAL)
    wire(ax,[(17,59),(17,52)])
    wire(ax,[(17,59),(17,56),(40,56),(40,43.5),(42,43.5)])
    wire(ax,[(60,59),(60,52)])
    wire(ax,[(60,59),(60,55),(103,55),(103,52)])
    wire(ax,[(103,59),(103,57),(82,57),(82,43.5),(78,43.5)],color=ORANGE)
    box(ax,2,10,30,17,"外部 L2 / DRAM\n一致性与全局顺序\n不属于本图 SM 容量",face="white",edge=GRAY)
    box(ax,42,10,36,17,"SMEM owner / RMW\nshared atomic / barrier\nbyte 访问与可见性")
    box(ax,88,10,30,17,"TMEM allocator / lease\ntcgen05 alloc / dealloc\n矩阵完成与写回")
    wire(ax,[(17,35),(17,27)])
    wire(ax,[(60,35),(60,27)],dashed=True)
    wire(ax,[(103,35),(103,27)],dashed=True)
    save(fig,"04_memory_hierarchy")


def memory_sync():
    fig,ax=canvas(5,"memory / proxy 与异步同步","SMEM producer 可见性和 Tensor 完成分别跟踪；同步由规定的顺序与事件建立。")
    box(ax,2,63,116,8,"有序入口捕获 producer sequence / fence cutoff；后发写不能延长已捕获的等待集合",face="white",edge=GRID)
    box(ax,2,44,30,14,"SMEM 写入\nbank commit\n保留通知责任")
    box(ax,42,44,34,14,"collector invalidate\nfuture reuse 实际失效\n当前 snapshot 保持",face=MINT,edge=TEAL)
    box(ax,86,44,32,14,"proxy bridge\ncutoff 内责任完成\n发布可见性 token")
    wire(ax,[(32,51),(42,51)])
    wire(ax,[(76,51),(86,51)])
    box(ax,2,17,30,20,"Tensor 完成域\nnormal MCS / full\nSMEM-A MMA A-read",face=MINT,edge=TEAL)
    box(ax,42,17,28,20,"commit 快照\n受理后固定 cutoff\nwait / event 管理")
    box(ax,80,17,38,20,"barrier agent\nSMEM opaque b64 对象\n原子更新落地 → ack",face=WARM,edge=ORANGE)
    wire(ax,[(32,27),(42,27)])
    wire(ax,[(70,27),(80,27)])
    text(ax,2,9,"ld/st：独立 per-warp wait；A-read 早通知不提前释放完整命令的 token / lease。",ha="left",color=GRAY)
    save(fig,"05_memory_async_sync")


def tensor_malu():
    fig,ax=canvas(6,"tcgen05 与点积 MALU 集成","A/B 格式、scale 格式和 BLOCK16/32 独立描述；合法组合由前端过滤。")
    box(ax,2,59,28,12,"tcgen05 命令\n捕获 descriptor")
    box(ax,36,59,29,12,"legalizer / OpTable\nTMEM allocator / lease")
    box(ax,72,59,46,12,"tile / layout planner\nlogical K、packed K 与 scale 游标")
    wire(ax,[(30,65),(36,65)])
    wire(ax,[(65,65),(72,65)])
    box(ax,2,30,28,22,"SMEM / TMEM 源\nA/B 与正式 C\nscale / metadata\n保存不可变快照")
    box(ax,36,30,29,22,"DOT 事务 adapter\ndescriptor + C 一次\n独立 c_scale_shift\nK 跨 operand beats\n单 output response")
    box(ax,72,30,46,22,"MALU：仅向量 DOT\nREF：现有 SV PROJECT_EXACT\nPERF：拟议，尚未实现\n标量 FMA / SFU 属其他执行域",face=MINT,edge=TEAL)
    wire(ax,[(95,59),(95,55),(16,55),(16,52)])
    wire(ax,[(30,41),(36,41)])
    wire(ax,[(65,41),(72,41)])
    box(ax,2,8,28,14,"完整 tcgen05 外壳\n搬移 / 分配 / 异步\n不塞入 dot 核心")
    box(ax,36,8,29,14,"D write ack\nfull-done / retire\n释放 token / lease",face=WARM,edge=ORANGE)
    box(ax,72,8,46,14,"MALU 内最终 round / pack\nD → WBQ → TMEM write ack\nPROJECT_EXACT，不宣称设备 bitfit")
    wire(ax,[(95,30),(95,22)])
    wire(ax,[(72,15),(65,15)],color=ORANGE)
    save(fig,"06_tensor_malu_integration")


def instruction_lowering():
    fig,ax=canvas(7,"指令覆盖与编译 lowering","PTX 是虚拟 ISA；编译器 lowering、项目指令边界和 SM 硬件译码分别定义。")
    top=[(2,22,"PTX / target\n声明与指令输入"),(30,24,"parse / typecheck\n地址空间与修饰符"),
         (62,24,"合法 tuple 核查\ntarget / profile"),(94,24,"compiler lowering\n保留可观察语义")]
    for x,w,label in top: box(ax,x,58,w,13,label)
    for (x,w,_),(nx,_,_) in zip(top,top[1:]): wire(ax,[(x+w,64.5),(nx,64.5)])
    box(ax,2,33,54,18,"能力与实现状态表\n现有 / 拟议 / 未实现分别标注\n不支持：明确诊断或 capability 关闭",face=WARM,edge=ORANGE)
    box(ax,68,33,50,18,"项目 ISA / 规范化 IR 合同\n编码、ABI、控制与副作用\n编译器产物进入硬件前端")
    wire(ax,[(74,58),(74,55),(29,55),(29,51)],color=ORANGE)
    wire(ax,[(106,58),(106,51)])
    box(ax,2,8,54,18,"覆盖与验证矩阵\n格式 × opcode 的合法组合逐项核对\n数值、异常、顺序与随机反压分别验证")
    box(ax,68,8,50,18,"SM fetch / decode / typed uop\nINT / FP / FMA / SFU\nLSU / atomic / sync / Tensor",face=MINT,edge=TEAL)
    wire(ax,[(93,33),(93,26)])
    wire(ax,[(68,42),(61,42),(61,17),(56,17)],dashed=True)
    save(fig,"07_instruction_lowering")


if __name__=="__main__":
    drawings={"01_sm_overview":overview,"02_warp_cta_control":warp_control,
              "03_register_execution":register_execution,"04_memory_hierarchy":memory_hierarchy,
              "05_memory_async_sync":memory_sync,"06_tensor_malu_integration":tensor_malu,
              "07_instruction_lowering":instruction_lowering}
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only",nargs="+",choices=drawings)
    args=parser.parse_args()
    ROOT.mkdir(parents=True,exist_ok=True)
    selected=args.only or list(drawings)
    for name in selected: drawings[name]()
    print(f"Generated {len(selected)} SM PNG/SVG pairs (2400 ×1608).")
