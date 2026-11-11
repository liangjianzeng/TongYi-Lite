#!/usr/bin/env python3
# [npu-line] G3: DLC tensor-dtype census (schema: graph={tensors: dict[name]->{id,
# data_type, unquantized_data_type, permute_order_to_src, quant_params}, nodes: dict}).
# data_type numerics: 534=FLOAT_16 562=FLOAT_32 776=SFIXED_POINT_8 1032=UFIXED_POINT_8.
# Focus: FC/MatMul input dtypes + shapes + permute metadata (double-transpose check with
# FIXUP5's physical OI transposition). Usage: python3 mcp5_93_dlc_dtype.py <tag>...
import json
import sys

DT = {534: 'f16', 562: 'f32', 776: 's8', 1032: 'u8'}


def dt(x):
    return DT.get(x, x)


for tag in sys.argv[1:] or ['w8nc640_l0']:
    g = json.load(open('/home/liang/w4sim/ctx_%s/dlcjson' % tag))['graph']
    tmap = g['tensors']
    f32 = [n for n, t in tmap.items() if t.get('data_type') == 562]
    mixed = [n for n, t in tmap.items()
             if t.get('data_type') != t.get('unquantized_data_type')
             and t.get('data_type') in (534, 562)]
    print('==', tag, 'tensors:', len(tmap), 'FLOAT_32:', f32)
    print('   float tensors with unquantized_data_type != data_type:', len(mixed), mixed[:10])
    for name, o in g['nodes'].items():
        ty = o.get('type')
        if ty in ('FullyConnected', 'MatMul'):
            print('  %s %s' % (ty, name))
            for i in o.get('input_names', o.get('inputs', [])):
                t = tmap.get(i, {})
                print('      %-45s dt=%-4s dims=%-22s perm=%s' % (
                    i[:45], dt(t.get('data_type')), t.get('dims') or t.get('dimensions'),
                    t.get('permute_order_to_src')))
print('DTYPE_CENSUS_DONE')
