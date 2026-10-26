"""Draw logical architecture figures; no physical GPU implementation is implied."""
from pathlib import Path
import os

os.environ.setdefault('MPLCONFIGDIR', '/tmp/tcgen05-matplotlib')
os.environ.setdefault('XDG_CACHE_HOME', '/tmp/tcgen05-fontcache')
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch
from matplotlib import font_manager
import subprocess

ROOT = Path(__file__).resolve().parent
font_file = subprocess.check_output(
    ['fc-match', '-f', '%{file}', 'Noto Sans CJK SC'], text=True).strip()
if not font_file:
    raise RuntimeError('Install Noto Sans CJK SC before generating Chinese figures.')
font_manager.fontManager.addfont(font_file)
font_family = font_manager.FontProperties(fname=font_file).get_name()
plt.rcParams.update({'font.family': font_family, 'font.size': 13,
                     'svg.fonttype': 'path', 'axes.unicode_minus': False})
NAVY, TEAL, GRAY = '#163550', '#087f8c', '#526473'
PALE, GOLD, WHITE = '#edf5f8', '#fff1cf', '#ffffff'


def canvas(height=7.2):
    fig, ax = plt.subplots(figsize=(10.8, height))
    fig.patch.set_facecolor(WHITE)
    ax.set(xlim=(0, 10.8), ylim=(0, height))
    ax.axis('off')
    fig.subplots_adjust(0.01, 0.01, 0.99, 0.99)
    return fig, ax


def box(ax, xy, size, text, fill=PALE, fontsize=13, edge=TEAL):
    x, y = xy
    w, h = size
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle='round,pad=0.06,rounding_size=0.1',
                              facecolor=fill, edgecolor=edge, linewidth=1.5))
    ax.text(x+w/2, y+h/2, text, ha='center', va='center', color=NAVY,
            fontsize=fontsize, linespacing=1.55)


def arrow(ax, start, end, text=None, pos=None, dashed=False, color=TEAL, curve=0):
    ax.add_patch(FancyArrowPatch(start, end, arrowstyle='-|>', mutation_scale=15,
                                linewidth=1.6, color=color,
                                linestyle='--' if dashed else '-',
                                connectionstyle=f'arc3,rad={curve}'))
    if text:
        p = pos or ((start[0]+end[0])/2, (start[1]+end[1])/2+0.18)
        ax.text(*p, text, ha='center', va='center', color=GRAY, fontsize=11.8,
                bbox={'facecolor': WHITE, 'edgecolor': 'none', 'pad': 1.5})


def label(ax, x, y, text, size=12, color=GRAY, ha='left'):
    ax.text(x, y, text, color=color, fontsize=size, va='center', ha=ha, linespacing=1.55)


def save(fig, name):
    svg = ROOT / (name+'.svg')
    fig.savefig(svg)
    svg.write_text('\n'.join(line.rstrip() for line in svg.read_text().splitlines())+'\n')
    fig.savefig(ROOT / (name+'.png'), dpi=190)
    plt.close(fig)


def context():
    fig, ax = canvas()
    label(ax, 0.3, 6.85, 'tcgen05 Tensor：软件可观察的功能边界', 18, NAVY)
    box(ax, (0.3, 4.15), (2.45, 1.65), 'CTA / CTA pair\n指令发射与参与者\n每个家族遵守各自粒度')
    box(ax, (3.6, 4.15), (3.2, 1.65), '矩阵操作契约\nMMA / sparse / block scale\n.ws / collector 语义')
    box(ax, (7.65, 4.15), (2.8, 1.65), '存储对象\nSMEM 描述符 / TMEM\n寄存器及矩阵布局')
    arrow(ax, (2.8, 4.95), (3.5, 4.95))
    arrow(ax, (7.55, 4.95), (6.9, 4.95))
    box(ax, (0.3, 1.55), (2.45, 1.55), '资源与所有权\nalloc / dealloc\nallocation permit')
    box(ax, (3.6, 1.55), (3.2, 1.55), '完成与顺序契约\ncommit + mbarrier\nwait / fence / 线程同步')
    box(ax, (7.65, 1.55), (2.8, 1.55), '项目 MALU 边界\nD = C + Dot(A,B)\nTensor 运算的一部分', GOLD)
    arrow(ax, (1.53, 3.2), (1.53, 4.03))
    arrow(ax, (5.2, 4.03), (5.2, 3.2))
    arrow(ax, (7.55, 2.35), (6.9, 2.35))
    label(ax, 0.3, 0.65, '框图表示架构责任；不指定发射队列、物理计算阵列、端口或存储 bank。', 12.3)
    save(fig, '01_architecture_context')


def memory():
    fig, ax = canvas(7.7)
    label(ax, 0.3, 7.35, '矩阵操作数与存储：逻辑数据流', 18, NAVY)
    box(ax, (0.25, 5.55), (2.15, 1.0), 'Global Memory\n应用输入 / 输出')
    box(ax, (4.1, 5.4), (2.65, 1.3), 'Shared Memory\nA（可选） / B\n由寄存器内 64-bit 描述符定位', fontsize=12)
    arrow(ax, (2.48, 6.05), (4.0, 6.05), '例如 TMA', (3.2, 6.3))
    box(ax, (0.25, 2.85), (2.15, 1.3), 'Registers\nld / st 的线程分布\n结果后处理')
    box(ax, (4.1, 2.65), (2.65, 1.65), 'Tensor Memory\n可选 A / D_old → D_new\nscale / sparse metadata\n32-bit TMEM 地址', fontsize=12)
    arrow(ax, (2.5, 3.2), (4.0, 3.2), 'st', (3.25, 3.03))
    arrow(ax, (4.0, 3.8), (2.5, 3.8), 'ld', (3.25, 4.0))
    arrow(ax, (5.4, 5.3), (5.4, 4.4), 'cp', (5.75, 4.85))
    box(ax, (8.1, 3.6), (2.3, 1.65), '矩阵操作\nMMA / .sp / .ws\n可选解压缩等语义', GOLD)
    arrow(ax, (6.85, 5.7), (8.02, 4.95), 'A / B', (7.45, 5.65))
    arrow(ax, (6.85, 3.8), (8.02, 4.1), 'A / D_old / 辅助数据', (7.55, 3.57))
    arrow(ax, (8.25, 3.5), (6.65, 2.65), 'D_new', (7.6, 2.63))
    label(ax, 0.3, 1.7, 'shift：TMEM 中的数据移动；collector：仅暴露指令规定的复用语义。', 12.3)
    label(ax, 0.3, 1.08, 'TMA 不是 tcgen05 指令；SMEM 就绪与 tcgen05 完成属于不同同步责任。', 12.3)
    label(ax, 0.3, 0.45, '实际布局、访问区域及类型合法性必须按所选 kind / shape / CTA group 核查。', 12.3)
    save(fig, '02_memory_and_operands')


def lifetime():
    fig, ax = canvas(6.4)
    label(ax, 0.3, 6.02, 'TMEM 资源生命周期与所有权', 18, NAVY)
    xs = [0.25, 2.43, 4.61, 6.79, 8.97]
    labels = ['未分配', '已分配\n拥有有效区域', '使用中\n可有异步操作', '静默且无并发访问\n满足释放前提', '已释放\n地址不再有效']
    for x, t in zip(xs, labels):
        box(ax, (x, 3.9), (1.63, 1.35), t, fontsize=11.9)
    for x in xs[:-1]:
        arrow(ax, (x+1.73, 4.55), (x+2.08, 4.55))
    for x, t in zip([2.15, 4.33, 6.51, 8.69], ['alloc', '发射操作', '正确等待 / 同步', 'dealloc']):
        label(ax, x, 3.45, t, size=11.5, ha='center')
    box(ax, (2.45, 1.1), (5.9, 1.3), 'relinquish_alloc_permit：放弃继续申请的许可\n不释放已分配区域，也不代替完成等待', GOLD)
    arrow(ax, (3.25, 3.8), (3.9, 2.5), dashed=True)
    label(ax, 0.3, 0.42, 'cta_group::2 的分配/释放需 peer CTA 配合；释放前必须排除 peer 的并发访问。', 12.1)
    save(fig, '03_resource_lifecycle')


def completion():
    fig, ax = canvas(7.5)
    label(ax, 0.3, 7.1, '完成域不能混用：发射、输入读取、整体完成、寄存器可用', 16.7, NAVY)
    box(ax, (0.3, 5.3), (2.4, 1.05), 'MMA / cp / shift\n异步操作组')
    arrow(ax, (2.8, 5.83), (3.6, 5.83))
    box(ax, (3.7, 5.3), (2.55, 1.05), '普通 commit\n跟踪此前规定操作')
    arrow(ax, (6.35, 5.83), (7.05, 5.83))
    box(ax, (7.15, 5.3), (3.3, 1.05), 'mbarrier phase 完成\n后续线程执行相应同步')
    arrow(ax, (8.8, 5.2), (8.8, 4.4))
    box(ax, (7.15, 3.25), (3.3, 1.05), 'after_thread_sync fence\n再开始相关 TMEM 访问')
    arrow(ax, (7.05, 3.78), (6.35, 3.78))
    box(ax, (3.7, 3.25), (2.55, 1.05), 'tcgen05.ld\n异步读取 TMEM')
    arrow(ax, (3.6, 3.78), (2.8, 3.78))
    box(ax, (0.3, 3.25), (2.4, 1.05), 'wait::ld\n读取结果可使用')
    box(ax, (0.3, 1.05), (10.15, 1.2), '受限 commit：sync_restrict::shared::read::mma::a\n只观察相关 MMA 对 SMEM A 的读取完成 → 可按规范复用 A 区域；不能据此读取 D。', GOLD, fontsize=12.5)
    label(ax, 0.3, 0.4, '这是完成关系图，不表示固定延迟；受限 commit 另受目标 ISA 支持条件约束。', 12)
    save(fig, '04_async_completion')


def scale():
    fig, ax = canvas(7.5)
    label(ax, 0.3, 7.1, '数据格式、scale 格式与分组：三个独立的架构维度', 17, NAVY)
    box(ax, (0.3, 5.2), (3.05, 1.2), 'Afmt / Bfmt\n矩阵元素解释方式')
    box(ax, (3.9, 5.2), (3.05, 1.2), 'scale type\nUE8M0 / UE4M3 / UE5M3')
    box(ax, (7.5, 5.2), (2.95, 1.2), 'block 配置\n沿 K 的 16 或 32 元素')
    label(ax, 0.3, 4.55, '以下仅为 dense K=64 示例；A 每行与 B 每列分别使用各自 scale。', 12.5)
    for y, block, n in [(3.4, 16, 4), (2.15, 32, 2)]:
        label(ax, 0.3, y+0.25, f'BLOCK{block}', 13, NAVY)
        start, total = 2.15, 8.15
        for i in range(n):
            w = total/n
            lo, hi = i*block, (i+1)*block-1
            box(ax, (start+i*w+0.025, y-0.15), (w-0.075, 0.85),
                f'K[{lo}:{hi}]\nscale[{i}]', fill=PALE if i%2==0 else '#e1f0e7', fontsize=12)
    box(ax, (0.3, 0.55), (10.15, 0.9), 'sparse 需按压缩 K 与规定 scale layout 映射，不能直接套图。\n独立字段的合法性由 kind × type × scale × block × shape × target 联合校验。', GOLD, fontsize=11.8)
    save(fig, '05_scale_domains')


if __name__ == '__main__':
    for draw in [context, memory, lifetime, completion, scale]:
        draw()
    print('Generated 5 SVG and 5 PNG architecture figures.')
