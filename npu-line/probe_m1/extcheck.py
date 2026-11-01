import onnx, os, sys
from onnx.external_data_helper import uses_external_data
base = '/mnt/e/MyLLM_exp'
for name in ('spark_prefill_v4.onnx','spark_prefill_v5.onnx'):
    p = os.path.join(base, name)
    if not os.path.exists(p):
        print(name, 'MISSING'); continue
    m = onnx.load(p, load_external_data=False)
    missing, present = [], 0
    for init in list(m.graph.initializer):
        if uses_external_data(init):
            loc = None
            for e in init.external_data:
                if e.key == 'location': loc = e.value
            if loc is None: continue
            fp = os.path.join(base, loc)
            if os.path.exists(fp): present += 1
            else: missing.append(loc)
    # also scan all subgraphs
    def scan(g):
        for init in g.initializer:
            if uses_external_data(init):
                loc = next((e.value for e in init.external_data if e.key=='location'), None)
                if loc:
                    fp = os.path.join(base, loc)
                    if os.path.exists(fp): present += 0
                    else: missing.append(loc)
    print('%s: ext_present=%d missing=%d' % (name, present, len(missing)))
    for x in missing[:10]: print('   MISSING:', x)
