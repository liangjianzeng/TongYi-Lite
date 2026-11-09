# [C32] Convert a packed-4bit model bin (tar of per-tensor .raw) into an unpacked
# 8-bit-container bin + dataType-rewritten cpp, replicating (converter minus
# --pack_4_bit_weights) exactly:
#   - for every STATIC tensor whose cpp addTensor uses QNN_DATATYPE_SFIXED_POINT_4:
#     its tar member bytes b -> [b & 0xF, b >> 4]  (low nibble = even index; the
#     QnnTypes.h spec ignores upper bits above bitwidth=4, so zero-extension is valid)
#   - cpp: replace SFIXED_POINT_4 -> SFIXED_POINT_8 (bitwidth stays 4 in BW_AXIS)
# Usage: unpack_bin.py <in.cpp> <in.bin> <out.cpp> <out.bin>
import re, sys, tarfile, io
import numpy as np

incpp, inbin, outcpp, outbin = sys.argv[1:5]

cpp = open(incpp, 'r', encoding='utf-8').read()

# tensor names whose addTensor sets SFIXED_POINT_4
names = []
for m in re.finditer(r'VALIDATE\(model\.addTensor\("([^"]+)".{0,900}?dataType= QNN_DATATYPE_SFIXED_POINT_4', cpp, re.S):
    names.append(m.group(1))
print('SFIXED_POINT_4 tensors:', len(names))
assert names, 'no SFIXED_POINT_4 tensors found'

def member(tn):
    return re.sub(r'[^0-9A-Za-z_]', '_', tn) + '.raw'

want = {member(n): n for n in names}
stats = {'unpacked': 0, 'bytes_in': 0, 'bytes_out': 0}

ti = tarfile.open(inbin, mode='r|*')
to = tarfile.open(outbin, mode='w|')
for m in ti:
    if m.name in want:
        data = np.frombuffer(ti.extractfile(m).read(), dtype=np.uint8)
        n = data.size
        out = np.empty(2 * n, dtype=np.uint8)
        out[0::2] = data & 0xF   # even index in low nibble (pack order, verified vs native)
        out[1::2] = data >> 4
        info = tarfile.TarInfo(m.name)
        info.size = 2 * n
        info.mode = m.mode
        info.mtime = 0
        to.addfile(info, io.BytesIO(out.tobytes()))
        stats['unpacked'] += 1
        stats['bytes_in'] += n
        stats['bytes_out'] += 2 * n
        if stats['unpacked'] % 25 == 0:
            print('  unpacked', stats['unpacked'], 'MBin=', stats['bytes_in'] // 1048576, flush=True)
    else:
        to.addfile(m, ti.extractfile(m))
to.close()
print('members unpacked:', stats['unpacked'], 'MB in/out:', stats['bytes_in'] // 1048576, stats['bytes_out'] // 1048576)
assert stats['unpacked'] == len(names), (stats['unpacked'], len(names))

cpp2 = cpp.replace('QNN_DATATYPE_SFIXED_POINT_4', 'QNN_DATATYPE_SFIXED_POINT_8')
open(outcpp, 'w', encoding='utf-8', newline='\n').write(cpp2)
print('CPP_REWRITES', cpp.count('QNN_DATATYPE_SFIXED_POINT_4'))
print('UNPACK_OK', outbin)
