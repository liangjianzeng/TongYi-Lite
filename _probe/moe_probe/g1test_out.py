import struct, re
path = r"E:\Work\DgxSpark\TongYi-Lite\_probe\moe_probe\g1test_hdr2.bin"
data = open(path, "rb").read()
off = [0]
def rd(fmt):
    n = struct.calcsize("<"+fmt)
    v = struct.unpack_from("<"+fmt, data, off[0]); off[0] += n
    return v[0] if len(v)==1 else v
def rstr():
    n = rd("Q"); s = data[off[0]:off[0]+n].decode("utf8"); off[0] += n; return s
off[0] = 4
assert data[:4] == b"GGUF"
rd("I"); n_tensors = rd("Q"); n_kv = rd("Q")
FMT = {0:"B",1:"b",2:"H",3:"h",4:"I",5:"i",6:"f",7:"?",10:"Q",11:"q",12:"d"}
def rdval(t):
    if t==8: return rstr()
    if t==9:
        et = rd("I"); n = rd("Q")
        for _ in range(n): rdval(et)
        return None
    return rd(FMT[t])
for _ in range(n_kv):
    rstr(); t = rd("I"); rdval(t)
TN = {0:"F32",1:"F16",2:"Q4_0",3:"Q4_1",6:"Q5_0",7:"Q5_1",8:"Q8_0",14:"Q4_K_S",15:"Q4_K_M",18:"Q6_K",26:"BF16"}
from collections import Counter
c = Counter()
for _ in range(n_tensors):
    name = rstr(); nd = rd("I")
    dims = [rd("Q") for _ in range(nd)]
    otype = rd("I"); o = rd("Q")
    if re.match(r"blk\.\d+\.attn_output\.weight$", name) or name in ("output.weight","token_embd.weight"):
        c[(name, TN.get(otype, otype))] += 1
for k in sorted(c): print(k, c[k])
