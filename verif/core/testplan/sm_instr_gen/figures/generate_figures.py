#!/usr/bin/env python3
"""Draw execution-plan responsibilities; not a runner or execution evidence."""
from pathlib import Path
import importlib.util

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[4]
spec = importlib.util.spec_from_file_location('_testplan_plot_layout', REPO / 'docs/sm/figures/generate_figures.py')
draw = importlib.util.module_from_spec(spec); spec.loader.exec_module(draw)
draw.ROOT = ROOT
box, wire, text, save = draw.box, draw.wire, draw.text, draw.save


def canvas(number, title, subtitle):
    fig, ax = draw.plt.subplots(figsize=(10, 6.7), dpi=240)
    fig.patch.set_facecolor('white'); fig.subplots_adjust(left=.025, right=.975, bottom=.025, top=.98)
    ax.set(xlim=(0, 120), ylim=(0, 84)); ax.axis('off')
    text(ax, 2, 80, f'{number:02d}  {title}', size=19, bold=True, ha='left', color=draw.NAVY)
    text(ax, 2, 75.8, subtitle, ha='left', color=draw.GRAY)
    ax.plot([2, 118], [73.2, 73.2], color=draw.GRID, lw=1)
    text(ax, 2, 2.6, '执行级计划 · 全部动态测试 NOT_RUN · 实现门禁未开启 · 无 runner 实现', ha='left', color=draw.GRAY)
    return fig, ax


def case_execution():
    fig, ax = canvas(1, 'Case 执行与独立检查点', '固定 source SIG 与 TC 身份；参数、初态和每个检查点都必须可审查、可重放。')
    stages = [(2, 20, 'TC / source SIG\n固定 seed\nprofile / 参数\nsuite'),
              (27, 23, '准入与初始化\n能力 / 依赖 gate\nowner / 状态 / 内存'),
              (55, 19, '有序步骤\n至少 3 步\n真实事件推进'),
              (79, 18, '检查点\n至少 2 个\n触发与观测'),
              (102, 16, '独立 checker\n允许结果集合\n通过 / 失败')]
    for x, w, label in stages:
        box(ax, x, 50, w, 20, label, face=draw.MINT if x in {27, 102} else draw.PALE)
    for (x, w, _), (nx, _, _) in zip(stages, stages[1:]):
        wire(ax, [(x+w, 60), (nx, 60)])
    box(ax, 2, 29, 55, 15, 'Checkpoint 责任\n明确 trigger、observable、checker 和预期\n不能以 shadow 更新代替真实完成', face=draw.MINT, edge=draw.TEAL)
    box(ax, 63, 29, 55, 15, '阶段与覆盖边界\nP1 / P2 仅 GENERATOR 覆盖\nP3 / P4 的 DUT 覆盖须真实后端事件', face=draw.WARM, edge=draw.ORANGE)
    wire(ax, [(88, 50), (88, 47), (29, 47), (29, 44)], color=draw.ORANGE)
    box(ax, 2, 8, 116, 16, '结果与 artifacts：输入 / 初态 / 配置 / 事件 / 检查凭据 / 失败分类\n前置条件未满足 → BLOCKED；未启动 → NOT_RUN；禁止以计划静态通过替代动态 PASS\n规范 undefined、unspecified 与合法 allowed-set 分开，拒绝边界必须有明确契约')
    save(fig, '01_case_execution_checkpoints')


def campaigns():
    fig, ax = canvas(2, '回归 Suite、门禁与证据链', 'Suite 是精确 case 名单与种子预算；计划声明不能作为测试启动或覆盖收敛证据。')
    stages = [(2, 25, '六类 Suite\n精确 TC 名单\n固定 seed / 预算\n所需 phase'),
              (33, 25, 'Profile / 准入\n能力与依赖门禁\nenabled = false\n当前不可执行'),
              (64, 24, '未来执行后端\nrunner / adapter\n模型 / DUT\n本任务不实现'),
              (94, 24, '真实结果状态\nNOT_RUN\nBLOCKED\nPASS / FAIL 需证据\n不改写历史失败')]
    for x, w, label in stages:
        box(ax, x, 46, w, 24, label, face=draw.WARM if x == 33 else draw.PALE, edge=draw.ORANGE if x == 33 else draw.NAVY)
    for (x, w, _), (nx, _, _) in zip(stages, stages[1:]):
        wire(ax, [(x+w, 58), (nx, 58)])
    box(ax, 2, 25, 54, 15, 'P0：schema / 源 hash / 引用 / 双向关联\n106 TC ↔ 106 source SIG；75 CV\n静态通过；动态执行数仍为 0', face=draw.MINT, edge=draw.TEAL)
    box(ax, 64, 25, 54, 15, '超时、拒绝、失败必须按契约分类\n不能把工具缺失或非零 exit 当作负例命中\nReplay 需要完整 artifact 和版本身份', face=draw.WARM, edge=draw.ORANGE)
    wire(ax, [(106, 46), (106, 40)], color=draw.ORANGE)
    box(ax, 2, 8, 116, 12, '失败包：case / SIG / source hash / seed / profile / 初态 / 已发与已完成事件 / oracle / 日志\n重放、缩减和 waiver 保留身份；零 case、未检查返回、SYNTHETIC 日志均不能冒充真实 DUT PASS')
    save(fig, '02_campaign_gates_and_evidence')


if __name__ == '__main__':
    ROOT.mkdir(parents=True, exist_ok=True)
    case_execution(); campaigns()
    print('Generated two testplan PNG/SVG pairs (2400 x 1608); text-bound checks passed.')
