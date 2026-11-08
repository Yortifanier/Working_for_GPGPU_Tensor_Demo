#!/usr/bin/env python3
"""Draw planned generator verification responsibilities; not executed tests."""
from pathlib import Path
import importlib.util

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[4]
spec=importlib.util.spec_from_file_location('_vplan_plot_layout',REPO/'docs/sm/figures/generate_figures.py')
draw=importlib.util.module_from_spec(spec);spec.loader.exec_module(draw)
draw.ROOT=ROOT
box,wire,text,save=draw.box,draw.wire,draw.text,draw.save


def canvas(number,title,subtitle):
    fig,ax=draw.plt.subplots(figsize=(10,6.7),dpi=240)
    fig.patch.set_facecolor('white');fig.subplots_adjust(left=.025,right=.975,bottom=.025,top=.98)
    ax.set(xlim=(0,120),ylim=(0,84));ax.axis('off')
    text(ax,2,80,f'{number:02d}  {title}',size=19,bold=True,ha='left',color=draw.NAVY)
    text(ax,2,75.8,subtitle,ha='left',color=draw.GRAY)
    ax.plot([2,118],[73.2,73.2],color=draw.GRID,lw=1)
    text(ax,2,2.6,'vplan 规划 · 所有动态测试 NOT_RUN · P0 仅静态完整性检查',ha='left',color=draw.GRAY)
    return fig,ax


def generation():
    fig,ax=canvas(1,'发生、独立审计与验证责任链','生成器、合法性审计和结果 oracle 分开实现；计划流程不代表当前已可执行。')
    stages=[(2,18,'发生器\n候选 / 程序\nseed / profile'),
            (26,23,'独立合法性审计\n独立 rule / checker\n正向 / 受控负例'),
            (55,17,'adapter\n规范化提交\n身份与事件'),
            (78,18,'DUT / 模型\n接收与返回\n后端可用性'),
            (102,16,'scoreboard\n参考预期检查\n独立结果检查')]
    for x,w,label in stages:box(ax,x,51,w,19,label,face=draw.MINT if x==26 else draw.PALE)
    for (x,w,_),(nx,_,_) in zip(stages,stages[1:]):wire(ax,[(x+w,60.5),(nx,60.5)])
    box(ax,2,30,72,14,'正向通过后提交；负例遵守规定边界\nPTX undefined 不伪造 trap oracle\nP0 仅计划静态检查；动态测试均 NOT_RUN',face=draw.WARM,edge=draw.ORANGE)
    box(ax,82,30,36,14,'独立参考语义\n数值 / 顺序 / 完成\n与生成器实现分开',face=draw.MINT,edge=draw.TEAL)
    wire(ax,[(110,44),(110,51)],color=draw.ORANGE)
    box(ax,2,9,55,17,'GENERATOR coverage（P1 / P2）\nGENERATED / LEGALIZED\nREJECTED / CHECKED\n不计作 SM DUT 覆盖')
    box(ax,63,9,55,17,'DUT_SCENARIO（仅 P3 / P4）\nADMITTED / COMPLETED / CHECKED\nREPORT_CLASSIFIED / REJECTED\n必须取自真实 adapter / DUT 事件',face=draw.WARM,edge=draw.ORANGE)
    save(fig,'01_generation_and_checking')


def state_replay():
    fig,ax=canvas(2,'有状态程序与 replay artifact','状态、资源、依赖和异步完成分别建模；保留源身份与可重放检查凭据。')
    stages=[(2,26,'program IR\nseed / capability\n源 release / target\n指令与控制流'),
            (31,26,'状态 / owner\n线程 PC / GPR / CC\npredicate / mask\nSMEM / TMEM\ngeneration\n分配与回收'),
            (60,27,'依赖与异步责任\nRAW / WAR / WAW\nproxy / barrier / group\nsource reuse / full done'),
            (92,26,'资源与提交门控\n全有全无预约\n真实事件更新状态\n退出 / reset drain')]
    for x,w,label in stages:box(ax,x,47,w,23,label,face=draw.MINT if x==31 else draw.PALE)
    for (x,w,_),(nx,_,_) in zip(stages,stages[1:]):wire(ax,[(x+w,58.5),(nx,58.5)])
    text(ax,60,43.3,'按动态实例 / owner / generation 记录事件',color=draw.GRAY)
    wire(ax,[(105,47),(105,40),(60,40),(60,37)],color=draw.ORANGE)
    ax.add_patch(draw.FancyBboxPatch((2,8),116,29,boxstyle='round,pad=0,rounding_size=.9',facecolor='white',edgecolor=draw.GRID,linewidth=1.4,zorder=0))
    text(ax,60,33,'replay artifact：保存完整责任链，不只保存 seed',bold=True,color=draw.NAVY)
    box(ax,5,11,33,17,'seed / 工具版本\n规范与 profile 快照\ngenerator / audit hash')
    box(ax,43,11,34,17,'程序 / 编码 / 初态\nowner / 依赖 / 事件序列\ncapability / adapter 配置')
    box(ax,82,11,33,17,'期望结果 / 失败分类\n模型版本与校验凭据\n重放状态仍须真实执行',face=draw.WARM,edge=draw.ORANGE)
    save(fig,'02_state_and_replay')


if __name__=='__main__':
    ROOT.mkdir(parents=True,exist_ok=True)
    generation();state_replay()
    print('Generated two vplan PNG/SVG pairs (2400 x 1608); text-bound checks passed.')
