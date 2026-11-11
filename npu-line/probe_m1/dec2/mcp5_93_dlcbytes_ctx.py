#!/usr/bin/env python3
# [npu-line] G3: does DLC->ctx compose preserve packed s8 weight bytes verbatim?
# Green control: w8dec_l999head (device-green). Red: w8nc640_l0 (same writer path).
# params.bin inside the DLC directory is a zip member with zeroed CRC -> _expected_crc=None.
import io
import sys
import zipfile

CASES = [("w8dec_l999head", ["val_0"]),
         ("w8nc640_l0", ["val_13", "val_20", "val_112"])]
for tag, names in CASES:
    dlcd = "/home/liang/w4sim/ctx_%s/%s" % (tag, tag)  # single-file DLC zip container
    try:
        z = zipfile.ZipFile(dlcd)
        members = z.namelist()
    except Exception:
        # params.bin may be a plain blob or member files laid out differently
        z = None
        members = []
    ctx = open("/mnt/e/MyLLM_exp/serve_dec/%s_ctx.bin" % tag, "rb").read()
    print("==", tag, "ctx", len(ctx), "params members:", len(members))
    if z is None:
        blob = open(dlcd + "/params.bin", "rb").read()
        print("   raw params.bin size:", len(blob))
        # whole-file tail probe: last 64KB of params somewhere in ctx?
        print("   tail64k find:", ctx.find(blob[-65536:]))
        for nm in names:
            pass
    else:
        for inf in z.infolist():
            fp = z.open(inf)
            fp._expected_crc = None
            data = fp.read()
            hit = ctx.find(data[:min(len(data), 4194304)])
            print("   %-40s %-9d find=%d" % (inf.filename, len(data), hit))
print("DLCBYTES_DONE")
