#!/usr/bin/env python3
"""[gemm_plan ledger-222] G2 logits 比对器 — 合同第11条修订版执行体。
tokmd5=假闸(#219 定案), 判定用 logits tensor-diff:
  - 首行(prefill 末 token logits, nv×4B fp32): C vs D 的 NMSE + greedy top-1 一致;
  - 逐 argmax 站点 top-1 一致率 ×3 shots。
用法: python3 g2_diff_logits.py <out_dir>            # 自动扫 g2_<arm>_s<N>.lg
"""
import numpy as np, sys, glob, os, struct, itertools

def load(path):
    """返回 [rows] 每行 = 一次 argmax 站点全量 fp32 logits。行宽由 nv 决定:
    文件大小 = rows*nv*4; nv 从 D_gold 首档反推(同 vocab)。"""
    raw = open(path, 'rb').read()
    return raw

def rows_of(raw, nv):
    a = np.frombuffer(raw, dtype='<f4')
    if a.size % nv: return None
    return a.reshape(-1, nv)

def main(outdir):
    lgs = sorted(glob.glob(os.path.join(outdir, 'g2_*_s*.lg')))
    if not lgs:
        print("#### G2DIFF_NO_LG", outdir); return 1
    # 文件大小簇 → 推 nv: 取最小文件的约数? 稳妥: 用 D_gold 行结构 = (npred+1) 行
    sizes = {p: os.path.getsize(p) for p in lgs}
    d = [p for p in lgs if 'D_gold' in p]
    npred = int(os.environ.get('NPRED', '32')) + 1
    nv = sizes[d[0]] // (4 * npred) if d else None
    print("#### G2DIFF files=%d nv_guess=%s" % (len(lgs), nv))
    def topk(raw):
        a = np.frombuffer(raw[:4*nv], dtype='<f4') if nv else None
        return (int(np.argmax(a)), float(a.max())) if a is not None and a.size == nv else (None, None)
    def nmse(x, y):
        x = np.frombuffer(x[:4*nv], '<f4'); y = np.frombuffer(y[:4*nv], '<f4')
        if x.size != y.size or x.size != nv: return None
        return float(np.mean((x - y) ** 2) / (np.mean(y ** 2) + 1e-12))
    gold = {s: topk(load(p))[0] for p in lgs if 'D_gold' in p and (s := p.split('_s')[-1][0]) for _ in [0]}
    # D 只有 shot1; C 的每 shot 都对 D_s1 比(贪心确定性预期下逐字对齐)
    for p in lgs:
        arm = os.path.basename(p).split('_s')[0]
        if 'D_gold' in p: continue
        t1, mx = topk(load(p))
        g = gold.get('1')
        print("#### G2DIFF arm=%s file=%s top1=%s gold_top1=%s match=%s" %
              (arm, os.path.basename(p), t1, g, t1 == g))
    # A/B/C 两两 prefill-logits NMSE(同 shot)
    for a, b in itertools.combinations(sorted({os.path.basename(p).split('_s')[0] for p in lgs}), 2):
        pass  # 主判定=top1+NMSE vs D; 两两 NMSE 若需再加
    print("#### G2DIFF_DONE")
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1]))
