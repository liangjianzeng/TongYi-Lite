# -*- coding: utf-8 -*-
import io, glob, re, os

os.chdir(r"E:/DTXY/TongYi-Lite/third_party/llama.cpp/ggml/src/ggml-opencl/kernels")

new_block = '''// [dspark 2026-10-14] Scalar-float subgroup broadcast. 740's online compiler
// lacks float overloads of sub_group_broadcast entirely -> host passes
// -DSGB_SCALAR_BROKEN and broadcasts go through the uint-bitcast shim.
// 830 (E031.47) has working float broadcast but miscompiles kernels whose
// broadcasts go through an inline wrapper, even in pass-through form
// (NMSE~2.2, 2026-10-14) -> uses the direct builtin. All call sites are
// per-component scalar: no vector broadcast anywhere.
#ifdef SGB_SCALAR_BROKEN
inline float sgb_f(float v, uint lid) {
    return as_float(sub_group_broadcast(as_uint(v), lid));
}
#define SGB_BC(v, lid) sgb_f(v, lid)
#else
#define SGB_BC(v, lid) sub_group_broadcast(v, lid)
#endif'''

n_header = n_v8 = n_v4 = n_skip = 0

re_v8 = re.compile(r'^(\s*)(\w+) = SGB_BC8\((\w+), (\w+)\); \\\s*$')
re_v8d = re.compile(r'^(\s*)float8 (\w+) = SGB_BC8\((\w+), (\w+)\); \\\s*$')
re_v4 = re.compile(r'^(\s*)float4 (\w+) = SGB_BC4\((\w+), (\w+)\);\s*$')

def expand_v8(indent, var, src, lid):
    return [indent + '%s.s%d = SGB_BC(%s.s%d, %s); \\' % (var, k, src, k, lid) for k in range(8)]

for p in glob.glob('*.cl'):
    t = io.open(p, encoding='utf-8').read()
    if 'SGB_BC(' not in t:
        continue
    lines = t.split('\n')

    # 1) header rewrite (only for files still carrying the old shim block)
    if 'SGB_SCALAR_BROKEN' not in t:
        istart = next(i for i, l in enumerate(lines) if 'SGB bitcast shims' in l)
        iqcom = next((i for i in range(istart, len(lines))
                      if lines[i].startswith('#ifdef cl_qcom_reqd_sub_group_size')), None)
        if iqcom is None:
            # fallback: end = closing '}' of sgb_f8
            if8 = next(i for i in range(istart, len(lines)) if lines[i].startswith('inline float8 sgb_f8('))
            iend = next(i for i in range(if8 + 1, len(lines)) if lines[i] == '}')
        else:
            iend = max(i for i in range(istart, iqcom) if lines[i] == '#endif')
        lines[istart:iend + 1] = new_block.split('\n')
        n_header += 1
    else:
        n_skip += 1

    # 2) vector site expansion
    out = []
    for l in lines:
        m = re_v8d.match(l)
        if m:
            ind, var, src, lid = m.groups()
            out.append('%sfloat8 %s; \\' % (ind, var))
            out.extend(expand_v8(ind, var, src, lid))
            n_v8 += 1
            continue
        m = re_v8.match(l)
        if m:
            ind, var, src, lid = m.groups()
            out.extend(expand_v8(ind, var, src, lid))
            n_v8 += 1
            continue
        m = re_v4.match(l)
        if m:
            ind, var, src, lid = m.groups()
            out.append('%sfloat4 %s;' % (ind, var))
            out.append('%s%s.s0 = SGB_BC(%s.s0, %s); %s.s1 = SGB_BC(%s.s1, %s);' % (ind, var, src, lid, var, src, lid))
            out.append('%s%s.s2 = SGB_BC(%s.s2, %s); %s.s3 = SGB_BC(%s.s3, %s);' % (ind, var, src, lid, var, src, lid))
            n_v4 += 1
            continue
        out.append(l)

    t2 = '\n'.join(out)
    bad = [l for l in t2.split('\n')
           if ('SGB_BC8(' in l or 'SGB_BC4(' in l)
           and 'define' not in l and 'inline' not in l]
    assert not bad, (p, bad[:3])
    io.open(p, 'w', encoding='utf-8', newline='\n').write(t2)

print('headers:', n_header, '| skip(already new):', n_skip, '| v8 sites:', n_v8, '| v4 sites:', n_v4)
