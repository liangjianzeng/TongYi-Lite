#!/usr/bin/env python3
# [npu-line] GGUF KV header probe (MC prefill_ids fail-closed forensics): parse the
# device Q4's KV section; report eos_token_id storage form + tensor-info sanity.
import sys, struct, base64
sys.path.insert(0, "E:/MyLLM_exp/_repro/rb")
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
from mcp5_94_adbsock import AdbSock

ad = AdbSock("<redacted-tailscale>:5555")
PATH = sys.argv[1] if len(sys.argv) > 1 else "/data/local/tmp/minicpm5-2b-q4k.gguf"
ad.shell(f"dd if={PATH} of=/data/local/tmp/head.gguf bs=1M count=16 2>/dev/null")
b64 = ad.shell("base64 /data/local/tmp/head.gguf")
ad.shell("rm /data/local/tmp/head.gguf")
data = base64.b64decode("".join(b64.split()))
assert data[:4] == b"GGUF", data[:4]
off = 4
ver = struct.unpack_from("<I", data, off)[0]; off += 4
nt = struct.unpack_from("<Q", data, off)[0]; off += 8
nkv = struct.unpack_from("<Q", data, off)[0]; off += 8
print("ver", ver, "n_tensors", nt, "n_kv", nkv)
# GGUF v3 types: 0 u8,1 i8,2 u16,3 i16,4 u32,5 i32,6 f32,7 bool,8 str,9 arr,10 u64,11 i64,12 f64
FMT = {0: "<B", 1: "<b", 2: "<H", 3: "<h", 4: "<I", 5: "<i", 6: "<f",
       7: "<?", 10: "<Q", 11: "<q", 12: "<d"}


def rd_str(d, o):
    n = struct.unpack_from("<Q", d, o)[0]; o += 8
    return d[o:o + n].decode("utf-8", "replace"), o + n


for i in range(nkv):
    k, off = rd_str(data, off)
    t = struct.unpack_from("<I", data, off)[0]; off += 4
    if t == 9:  # array
        at = struct.unpack_from("<I", data, off)[0]; off += 4
        an = struct.unpack_from("<Q", data, off)[0]; off += 8
        if "eos" in k or "bos" in k or "eot" in k:
            if at == 8:
                print(f"{k} = ARRAY(string) n={an}")
            else:
                fmt = FMT[at]; vs = [struct.unpack_from(fmt, data, off + j * struct.calcsize(fmt))[0]
                                     for j in range(min(an, 4))]
                print(f"{k} = ARRAY({at}) n={an} head={vs}")
        if at == 8:  # string array: skip elements
            for _ in range(an):
                _, off = rd_str(data, off)
        else:
            off += an * struct.calcsize(FMT[at])
    elif t == 8:  # string value
        v, off = rd_str(data, off)
        if any(w in k for w in ("eos", "freq")):
            print(f"{k} = str {v[:40]!r}")
    else:
        fmt = FMT[t]
        v = struct.unpack_from(fmt, data, off)[0]; off += struct.calcsize(fmt)
        if any(w in k for w in ("eos", "freq", "vocab", "embedding_length", "head_count")):
            print(f"{k} = {v}")
print("kv end off", off, "(tensor-info section follows; names parsed next would need full header)")
# quick tensor-name spot check: raw scan for token_embd in the pulled head window
print("token_embd in head bytes:", b"token_embd" in data)
print("tokenizer.ggml.tokens in KV:", b"tokenizer.ggml.tokens" in data)
