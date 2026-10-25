import struct, re
path = r"E:\Work\DgxSpark\TongYi-Lite\_probe\moe_probe\g1test_hdr3.bin"
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
rows = {}
for _ in range(n_tensors):
    name = rstr(); nd = rd("I")
    dims = [rd("Q") for _ in range(nd)]
    otype = rd("I"); o = rd("Q")
    tname = TN.get(otype, str(otype))
    m = re.match(r"blk\.(\d+)\.(attn_q\.weight|attn_k\.weight|attn_v\.weight|attn_output\.weight|ssm_conv1d_q\.weight|ssm_conv1d_k\.weight|ssm_conv1d_v\.weight|ssm_f_a\.weight|ssm_g_a\.weight|ssm_beta\.weight|ssm_a$|ssm_dt\.bias|ssm_norm\.weight)$", name)
    if m:
        rows.setdefault(int(m.group(1)), {})[m.group(2)] = tname
ok = True
for b in sorted(rows):
    r = rows[b]
    proj_ok = all(r.get(x) == "Q4_0" for x in ("attn_q.weight","attn_k.weight","attn_v.weight","attn_output.weight"))
    aux_names = ["ssm_conv1d_q.weight","ssm_conv1d_k.weight","ssm_conv1d_v.weight","ssm_f_a.weight","ssm_g_a.weight","ssm_beta.weight","ssm_a","ssm_dt.bias","ssm_norm.weight"]
    aux_bad = [x for x in aux_names if x in r and r[x] != "F32"]
    aux_missing = [x for x in aux_names if x not in r]
    if b in (3, 10):
        print("blk", b, {k: r[k] for k in sorted(r)})
    if not proj_ok or aux_bad:
        ok = False
        print("BLK", b, "PROJ_OK" if proj_ok else "PROJ_BAD", "AUX_BAD", aux_bad, "AUX_MISSING", aux_missing)
print("GATE_TENSOR_CONDITION:", "ALL_OK" if ok else "HAS_VIOLATIONS")
