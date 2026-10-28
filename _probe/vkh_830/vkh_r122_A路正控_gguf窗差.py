#!/usr/bin/env python3
# [vkh R-122] A路(es_base origin-shift)正控枪：证明"换 es_base 读到的是不同专家数据"。
# 原理：ffn_gate_exps [2048,1536,64] q4_0 是单一大张量，A路=ggml_cl_subbuffer_from_parent(q, es_base*q_layer, ...)。
# 若张量数据区按 expert 连续布局，则第 e 个专家窗与第 e' 窗字节必须互异（正控）；
# 若全同 ⇒ A路平移形同虚设（负控实锤）。零设备、只读流式，双窗各采样 CHUNK 字节。
import struct, sys

PATH = sys.argv[1] if len(sys.argv) > 1 else "/home/jianzengliang/MyWork/TongYi-Lite/.modelxfer/lfm2.5-24b-a2b-q4_0.gguf"
TARGETS = ("ffn_gate_exps", "ffn_up_exps", "ffn_down_exps")


def rd(f, off, n):
    f.seek(off); return f.read(n)


# 判例: ggml enum Q4_0=2(无BF16于低位段), 32权重=18B。首版误按dtype2=BF16判"专家BF16"已当场平反(census无罪)。
with open(PATH, "rb") as f:
    assert rd(f, 0, 4) == b"GGUF", "not gguf"
    f.seek(8)
    n_tensors = struct.unpack("<Q", f.read(8))[0]; n_kv = struct.unpack("<Q", f.read(8))[0]
    def rstr():
        n = struct.unpack("<Q", f.read(8))[0]; return f.read(n).decode()
    SZ = {0:1,1:1,2:2,3:2,4:4,5:4,6:4,7:1}
    def skip(t, d=0):
        if t == 8: rstr()
        elif t == 9:
            ct = struct.unpack("<I", f.read(4))[0]; n = struct.unpack("<Q", f.read(8))[0]
            if ct == 8:
                for _ in range(n): rstr()
            elif ct in SZ: f.seek(n*SZ[ct], 1)
            elif d < 2:
                for _ in range(n): skip(ct, d+1)
        else: f.seek(SZ[t], 1)
    for _ in range(n_kv): rstr(); skip(struct.unpack("<I", f.read(4))[0])
    infos = []
    for _ in range(n_tensors):
        name = rstr(); nmd = struct.unpack("<I", f.read(4))[0]
        dims = [struct.unpack("<Q", f.read(8))[0] for _ in range(nmd)]
        dt = struct.unpack("<I", f.read(4))[0]; off = struct.unpack("<Q", f.read(8))[0]
        infos.append((name, dims, dt, off))
    data_start = (f.tell() + 31) // 32 * 32
    CHUNK = 1 << 20; checked = fails = 0
    for name, dims, dt, off in infos:
        if not any(t in name for t in TARGETS): continue
        if dt != 2:
            print(f"[skip] {name} dt={dt} != Q4_0(2)"); continue
        ne0, ne1, E = dims[0], dims[1], dims[2]
        ql = ne0//32*18*ne1
        base = data_start + off
        for a, b in ((0, E//2), (0, E-1), (E//3, E//3+1)):
            wa = (f.seek(base+a*ql), f.read(min(CHUNK, ql)))[1]
            wb = (f.seek(base+b*ql), f.read(min(CHUNK, ql)))[1]
            if wa == wb:
                print(f"[FAIL-同窗] {name} exp{a}==exp{b}"); fails += 1
        checked += 1
    print(f"#### R122_POSCTRL q4_0(18B/32w) checked={checked} fails={fails} verdict={'PASS' if fails==0 and checked==114 else 'CHECK'}")
