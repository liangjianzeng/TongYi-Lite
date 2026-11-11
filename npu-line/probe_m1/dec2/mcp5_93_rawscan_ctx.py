#!/usr/bin/env python3
# [npu-line] G3: are the s8 weight streams in the built ctx bit-identical to the cpp/bin
# raw files (the packer's ground truth)? scan the whole ctx blob for each raw's bytes.
# If found verbatim -> packing/layout OK, poison is downstream (HTP compute/encodings);
# if not -> the writer/compose mangled the weight bytes.
import sys

for tag in sys.argv[1:] or ['w8cpp_l0']:
    ctx = open('/mnt/e/MyLLM_exp/serve_dec/%s_ctx.bin' % tag, 'rb').read()
    print('==', tag, 'ctx bytes:', len(ctx))
    for name in ['val_6', 'val_13', 'val_20', 'val_112', 'val_114', 'val_115',
                 'attn_o_proj_weight_permute']:
        p = '/home/liang/w4sim/ctx_%s/obj/binary/%s.raw' % (tag, name)
        try:
            raw = open(p, 'rb').read()
        except Exception as e:
            print('  %-30s OPEN_FAIL %s' % (name, e))
            continue
        off = ctx.find(raw)
        print('  %-30s len=%-9d find=%s' % (name, len(raw), off))
print('RAWSCAN_DONE')
