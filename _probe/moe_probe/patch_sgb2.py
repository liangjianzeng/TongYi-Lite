# -*- coding: utf-8 -*-
import io, glob, os

os.chdir(r"E:/DTXY/TongYi-Lite/third_party/llama.cpp/ggml/src/ggml-opencl/kernels")

n = 0
for p in glob.glob('*.cl'):
    lines = io.open(p, encoding='utf-8').read().split('\n')
    out = []
    i = 0
    changed = False
    while i < len(lines):
        l = lines[i]
        if l == '#ifdef SGB_FLOAT_BROKEN' and i + 1 < len(lines) and lines[i + 1].startswith('#define SGB_BC'):
            # old-style defines block -> skip through matching #endif
            depth = 1
            i += 1
            while i < len(lines) and depth > 0:
                s = lines[i].strip()
                if s.startswith('#if'):
                    depth += 1
                elif s == '#endif':
                    depth -= 1
                i += 1
            changed = True
            continue
        out.append(l)
        i += 1
    if changed:
        t = '\n'.join(out)
        assert 'SGB_FLOAT_BROKEN' not in t or '#define SGB_BC' not in t.split('SGB_SCALAR_BROKEN')[0], p
        io.open(p, 'w', encoding='utf-8', newline='\n').write(t)
        n += 1
        print('cleaned:', p)
print('files cleaned:', n)
