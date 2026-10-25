import struct
path = r"E:\Work\DgxSpark\TongYi-Lite\_probe\moe_probe\g1test_hdr2.bin"
data = open(path, "rb").read()
off = [0]
def rd(fmt):
    n = struct.calcsize("<"+fmt)
    v = struct.unpack_from("<"+fmt, data, off[0]); off[0] += n
    return v[0] if len(v)==1 else v
def rstr():
    n = rd("Q"); s = data[off[0]:off[0]+n].decode("utf8"); off[0] += n; return s
magic = data[:4]; off[0] = 4
assert magic == b"GGUF", magic
ver = rd("I"); n_tensors = rd("Q"); n_kv = rd("Q")
FMT = {0:"B",1:"b",2:"H",3:"h",4:"I",5:"i",6:"f",7:"?",10:"Q",11:"q",12:"d"}
def rdval(t):
    if t==8: return rstr()
    if t==9:
        et = rd("I"); n = rd("Q")
        for _ in range(n): rdval(et)
        return f"arr[{n}]"
    return rd(FMT[t])
for _ in range(n_kv):
    k = rstr(); t = rd("I"); rdval(t)
TN = {0:"F32",1:"F16",2:"Q4_0",3:"Q4_1",6:"Q5_0",7:"Q5_1",8:"Q8_0",9:"Q8_1",10:"Q2_K",11:"Q3_K_S",12:"Q3_K_M",13:"Q3_K_L",14:"Q4_K_S",15:"Q4_K_M",16:"Q5_K_S",17:"Q5_K_M",18:"Q6_K",26:"BF16",30:"Q4_0_4_4",31:"Q4_0_4_8",32:"Q4_0_8_8"}
from collections import Counter
cnt = Counter(); proj = Counter()
for i in range(n_tensors):
    name = rstr(); nd = rd("I")
    dims = [rd("Q") for _ in range(nd)]
    otype = rd("I"); o = rd("Q")
    tname = TN.get(otype, str(otype))
    cnt[tname] += 1
    parts = name.split(".")
    suffix = parts[-2] + "." + parts[-1] if len(parts) >= 2 else name
    if suffix in ("attn_q.weight","attn_k.weight","attn_v.weight","attn_o.weight",
                  "ssm_q.weight","ssm_k.weight","ssm_v.weight","ssm_in.weight","ssm_out.weight"):
        proj[suffix + " " + tname] += 1
print("total tensors:", n_tensors)
print(cnt.most_common())
for k in sorted(proj): print(k, proj[k])
