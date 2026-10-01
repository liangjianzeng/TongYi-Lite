#!/usr/bin/env python3
"""Regenerate cjk.pdf: a valid Type1 font (WinAnsiEncoding) + ToUnicode CMap
that maps 1-byte glyph codes 1..4 to CJK U+4E00/U+5B57/U+8BED/U+6D4B.

注意（2026-10-01 修三个 fixture bug）：
1. 文本算子必须包在 BT/ET 里，否则 PDFTextStripper 忽略 Tj（输出为空）；
2. ToUnicode 的流关键字是 stream（曾误写成 startstream → CMap 无效）；
3. CMap 用标准 /CIDInit ... begincmap 包裹 + /CMapName（非 Identity 前缀）。"""

cmap_stream = (
    "/CIDInit /ProcSet findresource begin\n"
    "12 dict begin\n"
    "begincmap\n"
    "/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n"
    "/CMapName /Adobe-Identity-UCS def\n"
    "/CMapType 2 def\n"
    "1 begincodespacerange\n"
    "<00> <FF>\n"
    "endcodespacerange\n"
    "4 beginbfchar\n"
    "<01> <4E00>\n"
    "<02> <5B57>\n"
    "<03> <8BED>\n"
    "<04> <6D4B>\n"
    "endbfchar\n"
    "endcmap\n"
    "CMapName currentdict /CMapName def\n"
    "end\n"
    "end\n"
)
cmap_len = len(cmap_stream.encode('latin-1'))

# Tj 必须在 BT/ET 内，且先 Tf 选字体
content_stream = "BT\n/F1 12 Tf\n100 700 Td\n<01020304> Tj\nET\n"
content_len = len(content_stream.encode('latin-1'))

objs = [
    "<< /Type /Catalog /Pages 2 0 R >>",
    "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    "<< /Type /Page /Parent 2 0 R /Contents 5 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> >>",
    "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 6 0 R >>",
    f"<< /Length {content_len} >>\nstream\n{content_stream}endstream",
    f"<< /Length {cmap_len} >>\nstream\n{cmap_stream}endstream",
]

out = b"%PDF-1.4\n"
xref = [b"0000000000 65535 f \n"]
for i, body in enumerate(objs, start=1):
    xref.append(f"{len(out):010d} 00000 n \n".encode('latin-1'))
    out += f"{i} 0 obj\n{body}\nendobj\n".encode('latin-1')

xref_offset = len(out)  # startxref 必须指向 xref 表在文件中的绝对偏移
xref_table = b"xref\n0 " + str(len(xref)).encode('latin-1') + b"\n" + b"".join(xref)
out += xref_table
out += b"trailer\n<< /Root 1 0 R /Size " + str(len(objs) + 1).encode('latin-1') + b" >>\n"
out += b"startxref\n" + str(xref_offset).encode('latin-1') + b"\n%%EOF\n"

with open("cjk.pdf", "wb") as f:
    f.write(out)
print("wrote cjk.pdf", len(out), "bytes; cmap_len=", cmap_len, "content_len=", content_len, "xref_at=", xref_offset)
