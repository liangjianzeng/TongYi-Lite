#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
guard_bitrot_scan.py — C1-P2 S2 验收机检（2026-10-26）

扫描 ggml-opencl.cpp 的 ggml_backend_opencl_context 成员：
「声明落在 #ifdef 守卫内、而使用点落在守卫外」= bitrot（ADRENO=OFF 编译断）。
零命中 = S2 扫描门过。局部同名变量声明行不算使用（去假阳性）。

用法: python guard_bitrot_scan.py [path/to/ggml-opencl.cpp]
退出码: 0=零命中, 1=有命中。
"""
import re, sys

PATH = sys.argv[1] if len(sys.argv) > 1 else None
if PATH is None:
    import os
    PATH = os.path.join(os.path.dirname(__file__),
        '../../third_party/llama.cpp/ggml/src/ggml-opencl/ggml-opencl.cpp')

lines = open(PATH, encoding='utf-8', errors='ignore').read().split('\n')

# preprocessor guard-depth per line
depth = [0] * len(lines)
st = []
for i, l in enumerate(lines):
    s = l.strip()
    if re.match(r'#\s*(if|ifdef|ifndef)\b', s):
        depth[i] = len(st); st.append(i + 1)
    elif re.match(r'#\s*(else|elif)\b', s):
        depth[i] = len(st)
    elif re.match(r'#\s*endif\b', s):
        if st: st.pop()
        depth[i] = len(st)
    else:
        depth[i] = len(st)

# struct member collection
members = []
instruct = False
for i, l in enumerate(lines):
    if 'struct ggml_backend_opencl_context' in l:
        instruct = True; continue
    if instruct and l.startswith('};'):
        instruct = False; continue
    if not instruct:
        continue
    m = re.match(r'^\s+(?:cl_kernel|cl_program|cl_mem)\s+(\w+)', l)
    if m:
        members.append((m.group(1), i + 1, depth[i])); continue
    m = re.match(r'^\s+(?:bool|size_t|int|float|double)\s+(\w+)', l)
    if m:
        members.append((m.group(1), i + 1, depth[i]))

hits = []
for name, dl, dd in members:
    if dd == 0:
        continue
    use = re.compile(r'backend_ctx->' + name + r'\b')
    # also bare uses inside same struct's inline methods: 'name' token at depth 0
    for i, l in enumerate(lines):
        if i + 1 == dl or depth[i] != 0:
            continue
        if not use.search(l):
            continue
        # false-positive: line itself declares a local of same name (shadowing)
        if re.search(r'(?:cl_kernel|cl_program|cl_mem|bool|size_t|int|float|double|std::\w+)\s+'
                     + name + r'\b\s*(=|;|\[)', l):
            continue
        hits.append((name, dl, i + 1, l.strip()[:90]))

print(f'members checked: {len(members)}')
print(f'BITROT HITS: {len(hits)}')
for h in hits:
    print(f'  {h[0]} decl@{h[1]} (guarded) used@{h[2]} (unguarded): {h[3]}')
sys.exit(1 if hits else 0)
