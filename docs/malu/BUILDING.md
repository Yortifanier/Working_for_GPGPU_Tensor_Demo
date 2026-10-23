# 文档生成

DOCX/PDF 为设计评审稿，未实现 RTL。原始用户 PDF 不随仓库复制；引文页码及校验值见 research。

需要 Python、下列依赖、Noto CJK 字体。PDF 导出另需 LibreOffice。

```sh
python3 -m pip install -r docs/malu/requirements-docs.txt
python3 docs/malu/figures/generate_figures.py
python3 docs/malu/figures/generate_rubin_ratio.py
python3 docs/malu/build_doc.py
soffice --headless --convert-to pdf --outdir docs/malu docs/malu/MALU_design_v1.1.docx
```

生成器只修改文档产物，不执行 Git 操作。图片版权与出处见图注；工程图为项目方案，不能作为 NVIDIA 物理微架构证明。
