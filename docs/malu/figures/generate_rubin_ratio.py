"""Plot the retrieved Rubin product modes; no inferred hardware lane counts."""
from pathlib import Path
import os
os.environ.setdefault('MPLCONFIGDIR', '/tmp/malu-matplotlib')
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from matplotlib.font_manager import FontProperties

OUT = Path(__file__).resolve().parent
FONT = FontProperties(fname='/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc')
BOLD = FontProperties(fname='/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc')
plt.rcParams.update({'svg.fonttype': 'path', 'axes.unicode_minus': False})

fig = plt.figure(figsize=(10, 5.5), dpi=240, facecolor='white')
fig.text(.035, .94, '05  Rubin 单 GPU dense 模式配比', fontproperties=BOLD,
         fontsize=20, color='#173553')
fig.text(.035, .885, 'FP16/BF16 = 1；产品峰值参考，不是本项目实测或物理 lane 数。',
         fontproperties=FONT, fontsize=13.5, color='#52687B')
ax = fig.add_axes([.29, .28, .66, .52])
names = ['TF32', 'FP16 / BF16', 'FP8 / FP6 Training', 'NVFP4 Training']
ratios = [.5, 1, 4.375, 8.75]
pf = [2, 4, 17.5, 35]
colors = ['#7395AE', '#173553', '#087F8C', '#D98432']
for i, (name, ratio, flops, color) in enumerate(zip(names, ratios, pf, colors)):
    y = 3-i
    ax.barh(y, ratio, height=.56, color=color, zorder=3)
    ax.text(ratio+.13, y, f'{ratio:g}×  |  {flops:g} PFLOPS', va='center',
            fontproperties=BOLD, fontsize=13.5, color='#20364B')
ax.set_yticks([3, 2, 1, 0], names, fontproperties=FONT, fontsize=13.5)
ax.set_xlim(0, 11.6)
ax.set_ylim(-.6, 3.65)
ax.set_xticks([0, 2, 4, 6, 8, 10])
ax.tick_params(axis='both', length=0, labelsize=13.5, pad=9)
ax.grid(axis='x', color='#DDE6EB', zorder=0)
for spine in ax.spines.values():
    spine.set_visible(False)
fig.text(.035, .155, '另列：NVFP4 inference = 50 PFLOPS，官方脚注标为 sparse；不混入 dense 比例。',
         fontproperties=FONT, fontsize=13.5, color='#173553')
fig.text(.035, .097, '来源：NVIDIA Vera Rubin NVL72 产品页，单 GPU 列；脚注³ dense、² sparse。',
         fontproperties=FONT, fontsize=13.5, color='#52687B')
fig.text(.035, .043, '访问日期：2026-10-23；具体 A/B/C/D、scale 与 BLOCK 组合仍需对应合法模式。',
         fontproperties=FONT, fontsize=13.5, color='#52687B')
fig.savefig(OUT/'05_rubin_dense_ratio.png', dpi=240, facecolor='white')
fig.savefig(OUT/'05_rubin_dense_ratio.svg', facecolor='white')
plt.close(fig)
print('Generated Rubin dense reference figure from verified product values.')
