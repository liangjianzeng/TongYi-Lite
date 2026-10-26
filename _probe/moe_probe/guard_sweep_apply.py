#!/usr/bin/env python3
# [TYL C1-P2 S3 sweep] guard re-slice driver: hoist the portable noshuffle
# dense-MoE/q4_K family out of GGML_OPENCL_USE_ADRENO_KERNELS per
# _probe/moe_probe/guard_sweep_plan.json. Line numbers = HEAD 0d879d4.
# Every op asserts line content before applying; abort on mismatch.
import sys
P='third_party/llama.cpp/ggml/src/ggml-opencl/ggml-opencl.cpp'
L=open(P,encoding='utf-8').read().splitlines(keepends=True)
def g(n): return L[n-1]
GUARD='GGML_OPENCL_USE_ADRENO_KERNELS'
def assert_(n,sub):
    if sub not in g(n):
        print(f"ASSERT FAIL L{n}: want {sub!r} got {g(n)[:90]!r}"); sys.exit(1)
dels=[]; ins=[]; reps=[]   # dels=(a,b); ins=(after_line,[lines]); reps=(a,b,[lines])
def dele(a,b,sub):
    assert_(a,sub); dels.append((a,b))
def insa(a,sub,lines):
    assert_(a,sub); ins.append((a,lines))
def repl(a,b,sub,lines):
    assert_(a,sub); reps.append((a,b,lines))
HDR='    // [TYL C1-P2 sweep 2026-10-26] portable dense-MoE/q4_K support members —\n    // hoisted OUT of the Adreno guard: the Mesa production chain (ADRENO=OFF)\n    // builds and runs the noshuffle dense family on rusticl. Vendor build unchanged.\n'

# ---- 16. MUL_MAT dispatch (28172..28558) ----
dele(28172,28172,'#ifdef '+GUARD)
dele(28558,28558,'#endif // '+GUARD)
insa(28172,'',  [ '#ifdef '+GUARD+'\n'])
insa(28470,'',  [ '#endif // '+GUARD+' (f16 KQ/KQV + xmem arms)\n'])
insa(28480,'',  [ '        #ifdef '+GUARD+'  // q1_0 trans-weight arm (stub in OFF)\n'])
insa(28491,'',  [ '        #endif\n'])
insa(28498,'',  [ '        #ifdef '+GUARD+'  // q4_1/q5_0/q5_1/iq4_nl/q8_0 arms (stubs in OFF)\n'])
insa(28530,'',  [ '        #endif\n'])
insa(28542,'',  [ '        #ifdef '+GUARD+'  // q6_K/q5_K arms (stubs in OFF)\n'])
insa(28556,'',  [ '        #endif\n'])
# ---- 15. dense_loop body ----
dele(26534,26534,'#ifdef '+GUARD)
dele(26671,26677,'#else')
# ---- 14. q4_k helper ----
dele(25288,25288,'#ifdef '+GUARD)
dele(25844,25849,'#else')
insa(25364,'',  [ '        #ifdef '+GUARD+'  // bin path -> guarded ila helper\n'])
insa(25375,'',  [ '        #endif\n'])
repl(25382,25382,'const bool use_tiled =',
     ['        #ifdef '+GUARD+'\n', g(25382),
      '        #else\n',
      '        const bool use_tiled = false;  // [TYL sweep] tiled default-off on Mesa (gen UNKNOWN)\n',
      '        #endif\n'])
insa(25516,'',[ '        #ifdef '+GUARD+'\n'])
insa(25520,'',[ '        #else\n',
    '        kernel = use_mc3 ? backend_ctx->kernel_gemv_noshuffle_q4_k_f32_mc3\n',
    '               : use_q4k_o4 ? backend_ctx->kernel_gemv_noshuffle_q4_k_f32_o4\n',
    '                            : backend_ctx->kernel_gemv_noshuffle_q4_k_f32;\n',
    '        #endif\n'])
insa(25526,'',[ '        #ifdef '+GUARD+'  // tiled arg block (use_tiled false in OFF)\n'])
repl(25537,25537,'} else {',
     ['        } else\n', '        #endif\n', '        {\n'])
insa(25648,'',[ '        #ifdef '+GUARD+'  // dp4a/wimg dense prefill (default off on Mesa)\n'])
insa(25742,'',[ '        #endif\n'])
# ---- 13. q4_k ila region split (debug_dump out of guard) ----
dele(24990,24990,'#ifdef '+GUARD)
insa(25077,'',[ '#ifdef '+GUARD+'\n'])
# ---- 12. q4_0 helper ----
dele(23268,23268,'#ifdef '+GUARD)
dele(23581,23586,'#else')
insa(23318,'',[ '    #ifdef '+GUARD+'  // bin path -> guarded ila helper\n'])
insa(23331,'',[ '    #endif\n'])
insa(23415,'',[ '        #ifdef '+GUARD+'  // dp4a dense prefill (default off on Mesa)\n'])
insa(23465,'',[ '        #endif\n'])
# ---- 11. build blocks move ----
blocks=[(4411,4432),(4469,4544),(4545,4559),(4880,4897),(4982,5002)]
block_src=[]
for a,b in blocks:
    seg=L[a-1:b]
    depth=0
    for s in seg:
        t=s.strip()
        if t.startswith('#if'): depth+=1
        elif t.startswith('#endif'): depth-=1
    if depth!=0: print(f"BLOCK {a}..{b} #if unbalanced"); sys.exit(1)
    block_src.append((a,seg))
for a,b in blocks: dels.append((a,b))
move_lines=[
 '// [TYL C1-P2 sweep 2026-10-26] portable noshuffle/transpose build blocks —\n',
 '// hoisted OUT of the Adreno guard: the Mesa production chain (ADRENO=OFF)\n',
 "// must build/run the SAME dense noshuffle kernels today's ON+ICD Mesa\n",
 '// bundle runs (moe_probe4 Mesa leg). Vendor init order is unchanged.\n' ]
for a,seg in block_src: move_lines+=seg
insa(4409,'',move_lines)
# ---- 10. set_tensor q4_K tiled/convert ----
dele(13329,13331,'#else')
insa(13323,'',[ '#endif // '+GUARD+' (tiled convert, default-off on Mesa)\n'])
# ---- 9. set_tensor q4_K moe ----
dele(13096,13096,'#ifdef '+GUARD)
repl(13097,13097,'if (use_adreno_moe_kernels(backend_ctx, tensor)) {',
     ['        if (use_adreno_moe_kernels(backend_ctx, tensor) && moe_use_dense_loop(tensor->type)) {\n',
      '            // [TYL sweep] dense-loop storage layout hoisted OUT of the Adreno\n',
      '            // guard: matches the unguarded dense_loop dispatch at MUL_MAT_ID.\n'])
dele(13103,13103,'if (moe_use_dense_loop(tensor->type)) {')
dele(13248,13248,'')
insa(13249,'',[ '        #ifdef '+GUARD+'\n',
               '        if (use_adreno_moe_kernels(backend_ctx, tensor)) {\n',
               '            // vendor trans4_ns repack (dense branch above already returned)\n'])
# ---- 8. set_tensor q4_0 transpose/bin ----
dele(12073,12073,'#ifdef '+GUARD)
dele(12111,12111,'#endif // '+GUARD)
insa(12081,'',[ '            #ifdef '+GUARD+'  // bin 32b path (helper false in OFF)\n'])
repl(12105,12105,'} else {',
     ['            } else\n', '            #endif\n', '            {\n'])
# ---- 7. set_tensor q4_0 convert selection ----
dele(12042,12042,'#ifdef '+GUARD)
dele(12049,12051,'#else')
# ---- 6. set_tensor q4_0 moe ----
dele(11952,11952,'#ifdef '+GUARD)
repl(11954,11954,'if (use_adreno_moe_kernels(backend_ctx, tensor)) {',
     ['        if (use_adreno_moe_kernels(backend_ctx, tensor) && moe_use_dense_loop(tensor->type)) {\n',
      '            // [TYL sweep] dense-loop storage layout hoisted OUT of the Adreno\n',
      '            // guard: matches the unguarded dense_loop dispatch at MUL_MAT_ID.\n'])
dele(11960,11960,'if (moe_use_dense_loop(tensor->type)) {')
dele(12004,12004,'}')
insa(12005,'',[ '        #ifdef '+GUARD+'\n',
               '        if (use_adreno_moe_kernels(backend_ctx, tensor)) {\n',
               '            // vendor trans4_ns repack (dense branch above already returned)\n'])
# ---- 5. glu-fused dispatch ----
dele(9968,9968,'#ifdef '+GUARD)
dele(9982,9982,'#endif')
# ---- 3/4. glu fused function bodies ----
dele(9420,9420,'#ifdef '+GUARD); dele(9527,9532,'#else')
dele(9539,9539,'#ifdef '+GUARD); dele(9626,9631,'#else')
# ---- 2. helpers transpose_2d/subbuffer ----
dele(7814,7814,'#ifdef '+GUARD)
dele(7924,7924,'#endif // '+GUARD)
# ---- 1. member decl moves (from guard 1511..1585) ----
cut=[(1512,1522),(1526,1529),(1541,1541),(1544,1544),(1553,1555)]
seg=[]
for a,b in cut:
    for n in range(a,b+1):
        if GUARD in g(n): print(f"cut range {a}..{b} hits directive at {n}"); sys.exit(1)
    seg.append(L[a-1:b])
    dels.append((a,b))
move=[HDR]+seg[0]+seg[1]+seg[2]+seg[3]+seg[4]+['\n']
insa(1510,'',move)
for n,subs in [
  (1512,'Transpose'),(1513,'program_transpose'),(1521,'kernel_transpose_16_4x1'),
  (1526,'4096_1_11008'),(1529,'32000_1_4096'),(1541,'q4_k_f32_o4'),
  (1544,'kernel_gemm_noshuffle_q4_k_f32'),(1553,'q4_k_f32_r1'),(1555,'q4_k_f32_cok')]:
    assert_(n,subs)
# ---- apply ----
dset={}
for a,b in dels: dset[a]=(a,b)
ins_map={}
for a,lines in ins: ins_map.setdefault(a,[]).extend(lines)
repl_map={}
for a,b,lines in reps: repl_map[a]=(b,lines)
out=[]
skip_until=0
for n in range(1,len(L)+1):
    if n<skip_until: continue
    if n in dset:
        skip_until=dset[n][1]+1
        continue
    if n in repl_map:
        b,lines=repl_map[n]
        out.extend(lines); skip_until=b+1
        continue
    if n in ins_map: out.extend(ins_map[n])
    out.append(L[n-1])
open(P,'w',encoding='utf-8',newline='').write(''.join(out))
print("applied: dels",len(dels),"ins",len(ins),"reps",len(reps))
